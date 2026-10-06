import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

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
        "not_granted", "That design piece was not sent to this thread. design_get reads only the copies sent with its messages.")
    static let tooMany = DesignReferenceError(
        "too_many_references", "A message carries at most \(DesignReferenceRecord.maxPerMessage) design references.")
    static let noCopy = DesignReferenceError(
        "no_copy", "The copy sent with that message is no longer kept. Ask the user to send the reference again.")
    static let noRenderer = DesignReferenceError("render_unavailable", "Shepherd can't draw design pieces here.")
    static func versionGone(_ revision: UInt64) -> DesignReferenceError {
        DesignReferenceError("version_gone", "Version \(revision) of that design is no longer kept. Send the newer version from its chip, or pick the piece again.")
    }
}

/// A reference pinned for a composer, the @ picker or the Implement sheet: the piece at the
/// revision it was picked at (its source kept, so the send sends that version even if the design
/// moves on), what the host read of it, and what it will send.
public struct PreparedDesignReference: Hashable, Sendable {
    /// Pinned, and labelled for chips and menus.
    public var reference: DesignReference
    public var design: String
    public var boardTitle: String?
    public var pageTitle: String? = nil
    public var elementLabel: String?
    public var elementName: String?
    public var width: Double?
    public var height: Double?
    /// The Implement sheet's footer counts (`DesignReferencePresentation.sends`).
    public var outline: DesignReferenceOutline

    /// The element's name and words ("card “Checkout funnel”"), else the board's title, else the
    /// design's name: what "Implement …" and the toasts name.
    public var piece: String {
        DesignReferencePresentation.piece((reference.kind, design, boardTitle ?? reference.board?.stem,
                                           reference.element.map { _ in DesignReferenceReading.elementTitle(name: elementName, label: elementLabel) }),
                                           page: pageTitle ?? reference.page)
    }
}

/// A reference a send resolved and kept: its copy, the record pi reads, and the grant it makes.
struct SentDesignReference: Sendable {
    var payload: DesignReferencePayload
    var record: DesignReferenceRecord
    var grant: DesignGrant
}

/// Resolves, keeps and reads references off the server's queue: the design store and the copies'
/// store read and write on their own queues, the app draws on the main thread.
struct DesignReferenceService: Sendable {
    let server: SessionServer

    /// The piece's sources at the version a reference names.
    struct Resolved: Sendable {
        var design: Design
        var snapshot: DesignSnapshot
        var revision: UInt64
        /// The board (a board or element reference) or the boards held (a whole design).
        var boards: [(source: DesignBoardSource, isCurrent: Bool)]
        /// How many boards the design had at `revision`.
        var boardCount: Int
        var elementLabel: String?
        var elementName: String?
        var systems: [DesignSystemInstalled]
        var files: DesignExportFiles
        var renderSHA: String
    }

    /// The design, the board and the element as the reference names them, at its revision when a
    /// reference pinned the board then (else as they are now, pinned now). `exact` (a send) refuses
    /// a revision that is not kept instead of taking the design as it is now: only "Send vN"
    /// sends a newer version.
    func resolve(_ reference: DesignReference, state: ShepherdState, exact: Bool = false) async throws -> Resolved {
        guard reference.host == .local else { throw DesignReferenceError.remote }
        guard let design = state.designs.first(where: { $0.id == reference.designID }), !design.buildsSystem else {
            throw DesignReferenceError("no_such_design", "That design is no longer here.")
        }
        do {
            var snapshot = try await server.designs.snapshot(reference.designID)
            var boards: [(source: DesignBoardSource, isCurrent: Bool)] = []
            var revision = snapshot.revision
            var boardCount = snapshot.index.boards.count
            let older = reference.revision.flatMap { $0 != snapshot.revision ? $0 : nil }
            if let page = reference.page {
                if let wanted = older, let render = try await server.designs.pinnedRender(reference.designID, revision: wanted, boards: []) {
                    guard render.files.index.pages?.contains(where: { $0.id == page }) == true else {
                        throw DesignReferenceError("no_such_page", "That page was not on the pinned canvas.")
                    }
                    let order = DesignReferenceReading.canvasOrder(render.files.index).filter { render.files.index.page(of: $0) == page }
                    for path in order {
                        guard let source = render.files.sources[path] else { throw DesignStoreError.noSuchBoard(path) }
                        let sha = DesignStore.sha256(Data(source.utf8))
                        boards.append((DesignBoardSource(path: path, source: source, sha256: sha, revision: wanted), sha == snapshot.boards[path]))
                    }
                    revision = wanted
                } else if let wanted = older, exact {
                    throw DesignReferenceError.versionGone(wanted)
                } else {
                    let pin = try await server.designs.pinPage(reference.designID, page: page)
                    boards = pin.boards.map { ($0, $0.sha256 == snapshot.boards[$0.path]) }
                    revision = pin.revision
                }
            } else if let board = reference.board {
                if let wanted = older, let pinned = try await server.designs.pinnedBoard(reference.designID, path: board, revision: wanted) {
                    boards = [(pinned, pinned.sha256 == snapshot.boards[board])]
                    revision = wanted
                } else if let wanted = older, exact {
                    throw DesignReferenceError.versionGone(wanted)
                } else {
                    guard snapshot.index.boards[board] != nil, snapshot.boards[board] != nil else { throw DesignStoreError.noSuchBoard(board) }
                    let now = try await server.designs.pinBoard(reference.designID, path: board)
                    boards = [(now, true)]
                    revision = now.revision
                }
            } else if let wanted = older, let kept = try await server.designs.pinnedDesign(reference.designID, revision: wanted) {
                // The boards it held then, as they were, even if the canvas has others first now.
                boards = kept.boards.map { ($0, $0.sha256 == snapshot.boards[$0.path]) }
                boardCount = kept.boardCount
                revision = wanted
            } else if let wanted = older, exact {
                throw DesignReferenceError.versionGone(wanted)
            } else {
                let order = DesignReferenceReading.canvasOrder(snapshot.index).filter { snapshot.boards[$0] != nil }
                let held = Array(order.prefix(DesignReferencePayload.maxBoards))
                let pinned = try await server.designs.pinBoards(reference.designID, paths: held, wholeDesign: boardCount)
                revision = pinned.first?.revision ?? snapshot.revision
                boards = pinned.map { ($0, $0.sha256 == snapshot.boards[$0.path]) }
            }
            if exact, let wanted = reference.revision, wanted != revision {
                throw DesignReferenceError.versionGone(wanted)
            }
            guard let render = try await server.designs.pinnedRender(reference.designID, revision: revision, boards: boards.map(\.source.path)) else {
                throw DesignReferenceError.versionGone(revision)
            }
            snapshot.index = render.files.index
            snapshot.revision = revision
            boardCount = reference.page != nil ? boards.count : render.files.index.boards.count
            var label: String?
            var name: String?
            if let element = reference.element, let source = boards.first?.source.source {
                guard let template = DesignTemplate(board: source), template.element(for: element) != nil else {
                    throw DesignReferenceError("no_such_element", "\(element) is not on \(reference.board?.rawValue ?? "the board") now.")
                }
                label = template.labels[element.tid]
                name = DesignReferenceReading.elementNoun(element, in: source) ?? template.element(for: element)?.name
            }
            return Resolved(design: design, snapshot: snapshot, revision: revision, boards: boards, boardCount: boardCount, elementLabel: label,
                            elementName: name, systems: render.systems, files: render.files, renderSHA: render.sha256)
        } catch let error as DesignStoreError {
            throw DesignReferenceError(error.code, error.description)
        }
    }

    /// What a piece's copy counts, from its sources: its declared styles, and the installed
    /// systems' tokens and components it reads. The same rules for the sheet's footer and the copy.
    static func reading(_ reference: DesignReference, sources: [String], systems: [DesignSystemInstalled])
        -> (styles: [String], tokens: [DesignReferencePayload.Token], components: [DesignReferencePayload.Component], system: String?) {
        var styles: [String] = []
        for source in sources {
            for style in DesignReferenceReading.declaredStyles(in: source, element: reference.element) where !styles.contains(style) {
                styles.append(style)
            }
        }
        let piece = sources.map { DesignReferenceReading.pieceSource($0, element: reference.element) }.joined(separator: "\n")
        let tokens = DesignReferenceReading.usedTokens(in: piece, systems: systems)
        let components = DesignReferenceReading.usedComponents(in: piece, systems: systems)
        let system = systems.first.map { $0.title ?? $0.namespace }
        return (styles, DesignReferenceReading.payloadTokens(tokens), DesignReferenceReading.payloadComponents(components), system)
    }

    /// Pins a reference for a composer or the sheet: resolved now (or at its pinned revision),
    /// the board's source kept, and what a send of it would carry.
    func prepare(_ reference: DesignReference, state: ShepherdState) async throws -> PreparedDesignReference {
        let resolved = try await resolve(reference, state: state)
        var pinned = reference.pinned(at: resolved.revision)
        let board = reference.board.flatMap { resolved.snapshot.index.boards[$0] }
        let title = board?.title.flatMap(DesignViewRecord.label)
        let pageTitle = reference.page.map { id in
            resolved.snapshot.index.pages?.first { $0.id == id }?.name.flatMap(DesignViewRecord.label) ?? id
        }
        let read = Self.reading(reference, sources: resolved.boards.map(\.source.source), systems: resolved.systems)
        let outline = DesignReferenceOutline(kind: reference.kind, styles: read.styles.count, tokens: read.tokens.count, system: read.system,
                                             boards: reference.board == nil ? resolved.boards.count : nil,
                                             boardCount: reference.board == nil ? resolved.boardCount : nil)
        pinned.label = DesignReference.label(design: resolved.design.name, board: reference.board.map { title ?? $0.stem },
                                             element: reference.element.map { _ in
                                                 DesignReferenceReading.elementTitle(name: resolved.elementName, label: resolved.elementLabel) }, page: pageTitle)
        return PreparedDesignReference(reference: pinned, design: resolved.design.name, boardTitle: title, pageTitle: pageTitle,
                                       elementLabel: resolved.elementLabel, elementName: resolved.elementName,
                                       width: board?.w, height: board?.h, outline: outline)
    }

    /// Resolves a reference at its revision and keeps its copy for `agentID`: the board's (or
    /// the boards') source, the tokens note, and what the app draws (the picture, the page, the
    /// element's markup and computed styles), then the manifest. Nothing is kept if any of it
    /// fails.
    func capture(_ reference: DesignReference, for agentID: AgentID, state: ShepherdState, at now: Double) async throws -> SentDesignReference {
        let resolved = try await resolve(reference, state: state, exact: true)
        let pinned = reference.pinned(at: resolved.revision)
        let id = UUID()
        let payloads = server.designReferencePayloads
        let folder = try await payloads.create(agentID: agentID, payload: id)
        do {
            let read = Self.reading(pinned, sources: resolved.boards.map(\.source.source), systems: resolved.systems)
            var request = DesignReferenceCaptureRequest(reference: pinned, boards: [], folder: folder, files: resolved.files)
            var sources: [String: Data] = [:]
            var payload = DesignReferencePayload(
                id: id, agentID: agentID, reference: pinned, design: resolved.design.name,
                elementLabel: resolved.elementLabel, elementName: resolved.elementName, revision: resolved.revision, capturedAt: now,
                styles: read.styles, tokens: read.tokens, components: read.components, system: read.system,
                pageTitle: pinned.page.map { id in
                    resolved.snapshot.index.pages?.first { $0.id == id }?.name.flatMap(DesignViewRecord.label) ?? id
                })
            payload.renderSHA = pinned.page != nil
                ? try await server.designs.pinnedRenderSHA(pinned.designID, revision: resolved.revision, page: pinned.page)
                : resolved.renderSHA
            if let board = pinned.board, let first = resolved.boards.first {
                let entry = resolved.snapshot.index.boards[board]
                payload.boardTitle = entry?.title.flatMap(DesignViewRecord.label)
                payload.width = entry?.w
                payload.height = entry?.h
                payload.boardSHA = first.source.sha256
                let name = DesignReferenceFileNames.source(pinned)
                sources[name] = Data(first.source.source.utf8)
                payload.source = .init(name: name, bytes: first.source.source.utf8.count)
                request.boards = [.init(path: board, source: first.source.source, isCurrent: first.isCurrent,
                                        picture: DesignReferenceFileNames.image(pinned), html: DesignReferenceFileNames.html(pinned))]
                if pinned.element != nil {
                    request.elementHTML = DesignReferenceFileNames.elementHTML(pinned)
                    request.elementStyles = DesignReferenceFileNames.elementStyles(pinned)
                }
            } else {
                var boards: [DesignReferencePayload.Board] = []
                for (index, held) in resolved.boards.enumerated() {
                    let path = held.source.path
                    let entry = resolved.snapshot.index.boards[path]
                    let name = DesignReferenceFileNames.boardSource(index, path)
                    sources[name] = Data(held.source.source.utf8)
                    boards.append(.init(board: path, title: entry?.title.flatMap(DesignViewRecord.label), width: entry?.w, height: entry?.h,
                                        sha256: held.source.sha256, source: .init(name: name, bytes: held.source.source.utf8.count)))
                    request.boards.append(.init(path: path, source: held.source.source, isCurrent: held.isCurrent,
                                                picture: DesignReferenceFileNames.boardImage(index, path),
                                                html: DesignReferenceFileNames.boardHTML(index, path)))
                }
                payload.boards = boards
                payload.boardCount = resolved.boardCount
            }
            let note = DesignReferenceFileNames.tokens(pinned)
            let noteText = Data(DesignReferenceReading.tokensNote(payload).utf8)
            sources[note] = noteText
            payload.tokensNote = .init(name: note, bytes: noteText.count)
            try await payloads.write(sources, agentID: agentID, payload: id)

            if !request.boards.isEmpty {
                let drawn = try await server.captureDesignReference(request)
                if pinned.board != nil {
                    payload.picture = drawn.boards.first?.picture
                    payload.html = drawn.boards.first?.html
                    payload.element = drawn.element
                    payload.elementStyles = drawn.elementStyles
                    payload.computedStyles = drawn.computedStyles
                } else {
                    for index in payload.boards?.indices ?? 0..<0 where index < drawn.boards.count {
                        payload.boards?[index].picture = drawn.boards[index].picture
                        payload.boards?[index].html = drawn.boards[index].html
                    }
                }
            }
            try await payloads.save(payload)
            let grant = DesignGrant(designID: pinned.designID, board: pinned.board?.rawValue, element: pinned.element?.description,
                                    label: resolved.elementLabel, revision: resolved.revision, boardSHA: payload.boardSHA,
                                    grantedAt: now, payload: id, page: pinned.page)
            return SentDesignReference(payload: payload, record: payload.record(folder: folder), grant: grant)
        } catch {
            await payloads.remove(agentID: agentID, payloads: [id])
            throw error
        }
    }

    // MARK: design_get

    /// design_get's answer for `aspect`, from the copy the thread was sent: never the design as
    /// it is now. Everything read from the design is fenced as data; files are the copy's.
    func answer(_ reference: DesignReference, aspect: DesignReferenceAspect, agent: Agent) async throws -> DesignReferenceAnswer {
        guard let grant = agent.designGrant(designID: reference.designID, board: reference.board?.rawValue,
                                            element: reference.element?.description, revision: reference.revision, page: reference.page),
              let payloadID = grant.payload else { throw DesignReferenceError.notGranted }
        let payloads = server.designReferencePayloads
        guard let payload = await payloads.load(agentID: agent.id, payload: payloadID),
              let folder = payloads.folder(for: agent.id, payload: payloadID) else { throw DesignReferenceError.noCopy }
        let versions = agent.designGrants(forPieceOf: grant).map(\.revision)
        let lead = "design_get \(aspect.rawValue) of \(payload.reference.string)"
        let lookedAt = DesignReferenceLookedAt.make(payload, aspects: [aspect])
        func path(_ file: DesignReferencePayload.File?) -> String? { file.map { folder.appendingPathComponent($0.name).path } }
        func listed(_ note: String, _ files: [String]) -> DesignReferenceAnswer {
            DesignReferenceAnswer(text: lead + "\n" + note + "\n" + files.map { "- \($0)" }.joined(separator: "\n"), files: files,
                                  lookedAt: lookedAt)
        }
        switch aspect {
        case .summary:
            return DesignReferenceAnswer(text: lead + "\n" + DesignReferenceData.fenced(DesignReferenceReading.summary(payload, versions: versions)),
                                         lookedAt: lookedAt)
        case .tokens:
            return DesignReferenceAnswer(text: lead + "\n" + DesignReferenceData.fenced(DesignReferenceReading.tokensReport(payload)),
                                         lookedAt: lookedAt)
        case .image:
            if let picture = path(payload.picture) {
                var answer = listed(payload.reference.element == nil ? "A PNG of the board at twice its size, as it was sent."
                                                                     : "A PNG of the element cut from its board, at twice its size, as it was sent.",
                                    [picture])
                answer.image = picture
                return answer
            }
            let pictures = (payload.boards ?? []).compactMap { path($0.picture) }
            guard !pictures.isEmpty else { throw DesignReferenceError("no_picture", "The copy holds no picture.") }
            return listed("A PNG of each board the copy holds, at twice its size, as it was sent. Read each with your read tool.", pictures)
        case .html:
            if let page = path(payload.html) {
                return listed("The board as a standalone page, as it was sent: no runtime, no scripts. Read it with your read tool.", [page])
            }
            let pages = (payload.boards ?? []).compactMap { path($0.html) }
            guard !pages.isEmpty else { throw DesignReferenceError("no_html", "The copy holds no page.") }
            return listed("Each board the copy holds as a standalone page, as it was sent. Read them with your read tool.", pages)
        case .element:
            guard payload.reference.element != nil else {
                throw DesignReferenceError("no_element", "This reference is a whole board, page or design: ask for its html or image, or its tokens.")
            }
            let files = [path(payload.element), path(payload.elementStyles)].compactMap { $0 }
            guard !files.isEmpty else { throw DesignReferenceError("no_element", "The copy holds no markup for the element.") }
            return listed("The element's markup as drawn, and its computed styles (JSON), as it was sent. Read them with your read tool.", files)
        case .changes:
            let sent = agent.designGrants(forPieceOf: grant)
            guard let earlier = sent.last(where: { $0.revision < grant.revision }), let earlierID = earlier.payload,
                  let before = await payloads.load(agentID: agent.id, payload: earlierID) else {
                let text = sent.contains(where: { $0.revision > grant.revision })
                    ? "This is the earliest version of this piece sent to this thread (revisions "
                        + versions.map(String.init).joined(separator: ", ") + "). Ask with a later ref's revision to see what changed since."
                    : "This thread was sent only revision \(grant.revision) of this piece, so there is nothing to compare. "
                        + "A newer version reaches you only when the user sends it."
                return DesignReferenceAnswer(text: lead + "\n" + text, lookedAt: lookedAt)
            }
            let text: String
            if payload.reference.board == nil {
                let old = await boardSources(before, agentID: agent.id)
                let new = await boardSources(payload, agentID: agent.id)
                text = DesignReferenceReading.designChanges(from: before.revision, to: payload.revision, before: old, after: new)
            } else {
                guard let oldFile = before.source, let newFile = payload.source,
                      let oldData = await payloads.read(agentID: agent.id, payload: before.id, file: oldFile.name),
                      let newData = await payloads.read(agentID: agent.id, payload: payload.id, file: newFile.name) else {
                    throw DesignReferenceError.noCopy
                }
                text = DesignReferenceReading.changes(reference: payload.reference, label: earlier.label ?? grant.label, from: before.revision,
                                                      to: payload.revision, before: String(decoding: oldData, as: UTF8.self),
                                                      after: String(decoding: newData, as: UTF8.self))
            }
            return DesignReferenceAnswer(text: lead + "\n" + DesignReferenceData.fenced(text), lookedAt: lookedAt)
        }
    }

    private func boardSources(_ payload: DesignReferencePayload, agentID: AgentID) async -> [(board: DesignPath, title: String?, source: String)] {
        var out: [(board: DesignPath, title: String?, source: String)] = []
        for board in payload.boards ?? [] {
            guard let file = board.source,
                  let data = await server.designReferencePayloads.read(agentID: agentID, payload: payload.id, file: file.name) else { continue }
            out.append((board.board, board.title, String(decoding: data, as: UTF8.self)))
        }
        return out
    }

    // MARK: Freshness

    /// How `reference` stands against its design now: against the copy a thread was sent
    /// (`payload`), else against the version it pinned. Never reads another Mac's design.
    func freshness(_ reference: DesignReference, payload: DesignReferencePayload?, state: ShepherdState) async -> DesignReferenceFreshness {
        guard reference.host == .local else { return .current }
        guard state.designs.contains(where: { $0.id == reference.designID }),
              let snapshot = try? await server.designs.snapshot(reference.designID) else { return .deleted }
        if let page = reference.page, snapshot.index.pages?.contains(where: { $0.id == page }) != true { return .deleted }
        let payloads = server.designReferencePayloads
        let pinnedSHA: String?
        if let payload { pinnedSHA = payload.renderSHA }
        else if let revision = reference.revision {
            pinnedSHA = try? await server.designs.pinnedRenderSHA(reference.designID, revision: revision, page: reference.page)
        } else { pinnedSHA = nil }
        let renderChanged: Bool
        if let pinnedSHA {
            renderChanged = (try? await server.designs.renderSHA(reference.designID, page: reference.page)) != pinnedSHA
        } else {
            // Old sent copies have no rendering fingerprint; don't call source equality fresh.
            renderChanged = reference.revision.map { $0 != snapshot.revision } ?? false
        }
        if let board = reference.board {
            guard snapshot.index.boards[board] != nil, let now = snapshot.boards[board] else { return .deleted }
            var before: String?
            var sha: String?
            if let payload {
                sha = payload.boardSHA
                if let file = payload.source, let data = await payloads.read(agentID: payload.agentID, payload: payload.id, file: file.name) {
                    before = String(decoding: data, as: UTF8.self)
                }
            } else if let revision = reference.revision,
                      let pinned = try? await server.designs.pinnedBoard(reference.designID, path: board, revision: revision) {
                sha = pinned.sha256
                before = pinned.source
            }
            guard let sha else {
                return reference.revision.map { $0 == snapshot.revision } ?? true ? .current : .updatedSince(latest: snapshot.revision, changes: [])
            }
            guard sha != now else {
                return renderChanged ? .updatedSince(latest: snapshot.revision, changes: []) : .current
            }
            guard let before, let after = try? await server.designs.board(reference.designID, path: board) else {
                return .updatedSince(latest: snapshot.revision, changes: [])
            }
            let label = payload?.elementLabel
            return .updatedSince(latest: snapshot.revision, changes: DesignReferenceReading.changeLines(
                reference: reference, label: label, before: before, after: after.source))
        }
        let order = DesignReferenceReading.canvasOrder(snapshot.index).filter { path in
            reference.page.map { snapshot.index.page(of: path) == $0 } ?? true
        }
        let current = order.compactMap { path in snapshot.boards[path].map { (board: path, title: snapshot.index.boards[path]?.title, sha256: $0) } }
        guard let payload, let held = payload.boards else {
            if reference.page != nil, pinnedSHA != nil {
                return renderChanged ? .updatedSince(latest: snapshot.revision, changes: []) : .current
            }
            return reference.revision.map { $0 == snapshot.revision } ?? true ? .current : .updatedSince(latest: snapshot.revision, changes: [])
        }
        let before = held.map { (board: $0.board, title: $0.title, sha256: $0.sha256) }
        let heldAll = held.count == (payload.boardCount ?? held.count)
        let compared = heldAll ? current : current.filter { board in held.contains { $0.board == board.board } }
        let lines = DesignReferenceReading.designChangeLines(before: before, after: compared)
        return lines.isEmpty && !renderChanged ? .current : .updatedSince(latest: snapshot.revision, changes: lines)
    }

    // MARK: The @ picker

    /// This Mac's designs, their boards and elements, most recently active design first. Designs
    /// being built as design systems are not designs to reference.
    func mentionCatalog(state: ShepherdState) async -> DesignMentionCatalog {
        var catalog = DesignMentionCatalog()
        let designs = state.designs.filter { !$0.buildsSystem }.sorted { $0.lastActiveAt > $1.lastActiveAt }
        for design in designs {
            guard let snapshot = try? await server.designs.snapshot(design.id) else { continue }
            let entries = await server.designMentions.entries(for: design, snapshot: snapshot) {
                var sources: [DesignPath: String] = [:]
                for path in snapshot.index.boards.keys {
                    if let board = try? await server.designs.board(design.id, path: path) { sources[path] = board.source }
                }
                let systems = (try? await server.designs.installedSystems(design.id)) ?? []
                return (sources, systems.first.map { $0.title ?? $0.namespace })
            }
            guard let entries else { continue }
            catalog.designs.append(entries.design)
            catalog.pages[design.id] = entries.pages
            catalog.boards[design.id] = entries.boards
            catalog.elements.merge(entries.elements) { $1 }
        }
        return catalog
    }
}

/// Each design's @ picker rows as last derived, by its revision and name: a picker opening again
/// reads no board it read before unless the design changed.
final class DesignMentionCache: @unchecked Sendable {
    typealias Entries = (design: DesignMentionItem, pages: [DesignMentionItem], boards: [DesignMentionItem], elements: [String: [DesignMentionItem]])
    private struct Kept {
        var revision: UInt64
        var name: String
        var activeAt: Double
        var entries: Entries
    }
    private let lock = NSLock()
    private var kept: [DesignID: Kept] = [:]

    func entries(for design: Design, snapshot: DesignSnapshot,
                 read: () async -> (sources: [DesignPath: String], system: String?)) async -> Entries? {
        let cached = lock.withLock { kept[design.id] }
        if let cached, cached.revision == snapshot.revision, cached.name == design.name, cached.activeAt == design.lastActiveAt {
            return cached.entries
        }
        let (sources, system) = await read()
        guard let entries = DesignMentionCatalog.entries(design: design, snapshot: snapshot, sources: sources, system: system) else { return nil }
        lock.withLock {
            kept[design.id] = Kept(revision: snapshot.revision, name: design.name, activeAt: design.lastActiveAt, entries: entries)
        }
        return entries
    }
}
