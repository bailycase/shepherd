import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

// A design's canvas handing pieces to threads (DesignRefStates › From the canvas; RefImplementMenu,
// RefCopied, RefNoteBack): what is selected as a reference, Implement in a thread… and Copy
// reference from the board actions, the right-click menu, the design's ••• menu and their chords,
// and the notes threads leave back as their own pins.

/// What the canvas asks the app to do with a reference, and to read and remove notes.
struct DesignReferenceCanvasActions {
    /// Implement in a thread…: the sheet for the piece.
    var implement: (DesignReferenceSelection) -> Void
    /// Copy reference: the piece pinned, its string on the pasteboard, a toast.
    var copy: (DesignReferenceSelection) -> Void
    var notes: (DesignID) async throws -> [DesignThreadNote] = { _ in [] }
    var removeNote: (DesignID, UUID) async throws -> Void = { _, _ in }
    /// Open thread: nil when the thread is gone.
    var openThread: ((AgentID) -> Void)?
    var threadExists: (AgentID) -> Bool = { _ in false }
    var report: (String) -> Void = { _ in }
}

/// The piece a canvas hands to a thread: the whole design (no board), a board, or an element as
/// the canvas picked it (its rect, to cut its picture from the board's).
struct DesignReferenceSelection: Equatable {
    var designID: DesignID
    var designName: String
    var board: DesignPath?
    var boardTitle: String?
    var element: DesignElementPick?

    /// "card “Checkout funnel”", "A · Funnel first", "Checkout funnel dashboard": what menus and
    /// the sheet name.
    var piece: String {
        if let element { return Self.elementTitle(element) }
        if let board { return boardTitle ?? board.stem }
        return designName
    }

    /// design › board › element, for the sheet's line and a chip.
    var crumbs: [String] {
        [designName] + (board.map { [boardTitle ?? $0.stem] } ?? []) + (element.map { [Self.elementTitle($0)] } ?? [])
    }

    var reference: DesignReference? {
        DesignReference(designID: designID, board: board, element: element?.id)
    }

    /// An element as the boards name it: its `data-el` name and its words ("card “Checkout
    /// funnel”"), else what the canvas's tag says.
    static func elementTitle(_ element: DesignElementPick) -> String {
        let name = element.words == element.label ? nil : element.words
        // The canvas's tag leads with the element's name or tag ("card · Checkout funnel").
        let noun = element.tag.components(separatedBy: " · ").first.flatMap { $0.isEmpty ? nil : $0 }
        return DesignReferenceReading.elementTitle(name: name ?? noun, label: element.label)
    }
}

extension DesignScreenModel {
    // MARK: The selection as a reference

    /// What Implement in a thread… and Copy reference hand over: the latest pick (an element, or
    /// a board picked whole); with nothing selected, the whole design.
    func referenceSelection(designName: String) -> DesignReferenceSelection {
        let pick = picks.last
        let board = pick?.board
        let title = board.flatMap { snapshot?.index.boards[$0]?.title?.trimmingCharacters(in: .whitespacesAndNewlines) }
        return DesignReferenceSelection(designID: designID, designName: designName, board: board,
                                        boardTitle: title?.isEmpty == false ? title : nil, element: pick?.element)
    }

    var canReference: Bool { referenceActions != nil && snapshot != nil }

    func implementSelection(designName: String) {
        guard let actions = referenceActions, canReference else { return }
        actions.implement(referenceSelection(designName: designName))
    }

    func copySelectionReference(designName: String) {
        guard let actions = referenceActions, canReference else { return }
        actions.copy(referenceSelection(designName: designName))
    }

    // MARK: The right-click menu

    /// A right-click (CanvasContextMenu): what it landed on is picked first (unless it is already
    /// selected), then the menu offers Comment and Tweak, Implement in a thread… (⌘↩) and Copy
    /// reference (⇧⌘C), and Duplicate for its board. On the empty canvas it offers the design.
    func contextMenu(for pick: NWCanvasPick, designName: String, keys: KeybindingsStore) async -> [NWCanvasMenuItem] {
        guard tool != .pan else { return [] }
        let board = pick.board.flatMap(DesignPath.init)
        var element: DesignElementPick?
        if let board, let point = pick.point, let host { element = await host.hitTest(board, at: point) }
        closeComment()
        if let board {
            let already = picks.contains { $0.board == board && $0.element?.id == element?.id }
            if !already { setSelection([Pick(board: board, element: element)]) }
        } else {
            clearSelection()
        }
        return menuItems(designName: designName, keys: keys)
    }

    /// The right-click menu's items for what is selected now.
    func menuItems(designName: String, keys: KeybindingsStore) -> [NWCanvasMenuItem] {
        let selection = referenceSelection(designName: designName)
        var items: [NWCanvasMenuItem] = []
        if selection.board != nil {
            items.append(NWCanvasMenuItem(id: "comment", title: "Comment", symbol: "text.bubble") { [weak self] in
                guard let self else { return }
                if let element = selection.element { self.beginComment(on: element) } else { self.tool = .comment }
            })
            if tweak != nil {
                items.append(NWCanvasMenuItem(id: "tweak", title: "Tweak", symbol: "slider.horizontal.3") { [weak self] in
                    self?.paneTab = .tweak
                })
            }
            items.append(.divider("reference"))
        }
        if referenceActions != nil {
            let implement = keys.chord(for: .implementInThread), copy = keys.chord(for: .copyDesignReference)
            items.append(NWCanvasMenuItem(id: "implement", title: selection.board == nil ? "Implement \(selection.piece)…" : "Implement in a Thread…",
                                          symbol: "chevron.left.forwardslash.chevron.right", key: Self.menuKey(implement),
                                          command: implement.command, shift: implement.shift) { [weak self] in
                self?.implementSelection(designName: designName)
            })
            items.append(NWCanvasMenuItem(id: "copy", title: "Copy Reference", symbol: "link", key: Self.menuKey(copy),
                                          command: copy.command, shift: copy.shift) { [weak self] in
                self?.copySelectionReference(designName: designName)
            })
        }
        if let board = selection.board, canvasActions != nil {
            items.append(.divider("board"))
            items.append(NWCanvasMenuItem(id: "duplicate", title: "Duplicate", symbol: "plus.square.on.square") { [weak self] in
                self?.duplicate(board)
            })
        }
        return items
    }

    /// A chord's key as a menu item shows it ("\r" for Return).
    static func menuKey(_ chord: KeyChord) -> String? {
        guard !chord.option, !chord.control else { return nil }
        switch chord.key {
        case "return": return "\r"
        case "left", "right", "up", "down": return nil
        default: return chord.key
        }
    }

    // MARK: Notes back

    static let notePinPrefix = "note:"

    static func notePinID(_ id: UUID) -> String { notePinPrefix + id.uuidString }

    static func noteID(fromPin pin: String) -> UUID? {
        guard pin.hasPrefix(notePinPrefix) else { return nil }
        return UUID(uuidString: String(pin.dropFirst(notePinPrefix.count)))
    }

    /// The open note, while it is still on the design.
    var openThreadNote: DesignThreadNote? {
        openNote.flatMap { id in threadNotes.first { $0.id == id } }
    }

    /// Each note on a board this page shows, as the thread's pin on its element (on its board's
    /// corner while the element isn't found, or for a board's own note).
    func notePins(_ index: DesignIndex) -> [NWCanvasPin] {
        threadNotes.compactMap { note in
            guard index.boards[note.board] != nil, index.isOnPage(note.board, page) else { return nil }
            return NWCanvasPin(id: Self.notePinID(note.id), board: note.board.rawValue, rect: noteRect(note, index), number: 0,
                               style: .threadNote(note.thread))
        }
    }

    /// Where a note's pin goes: its element where a live board found it, else the board whole.
    func noteRect(_ note: DesignThreadNote, _ index: DesignIndex) -> CGRect {
        if let rect = noteRects[note.id] { return rect }
        guard let board = index.boards[note.board] else { return .zero }
        return CGRect(x: 0, y: 0, width: board.w, height: board.h)
    }

    func openNote(_ id: UUID) {
        guard threadNotes.contains(where: { $0.id == id }) else { return }
        draftElement = nil
        openComment = nil
        openNote = id
    }

    /// Reads the design's notes again (a pull, or a thread leaving one).
    func refreshNotes() async {
        guard let actions = referenceActions, let notes = try? await actions.notes(designID) else { return }
        applyNotes(notes)
    }

    /// Previews and tests: notes as the host would serve them.
    func applyNotes(_ notes: [DesignThreadNote]) {
        if notes != threadNotes { threadNotes = notes }
        if let openNote, !notes.contains(where: { $0.id == openNote }) { self.openNote = nil }
        let known = Set(notes.map(\.id))
        if noteRects.keys.contains(where: { !known.contains($0) }) { noteRects = noteRects.filter { known.contains($0.key) } }
        for board in Set(notes.filter { $0.element != nil }.map(\.board)) { locateNotes(on: board) }
    }

    /// Asks a live board where its noted elements are drawn now.
    func locateNotes(on board: DesignPath) {
        let onBoard = threadNotes.filter { $0.board == board && $0.element != nil }
        guard !onBoard.isEmpty, let host, host.liveBoards.contains(board) else { return }
        Task {
            guard let found = await host.locate(board, tids: onBoard.compactMap { $0.element?.tid }) else { return }
            var next = noteRects
            for note in onBoard {
                if let element = note.element, let pick = found[element.tid], pick.id.path == element.path { next[note.id] = pick.rect }
            }
            if next != noteRects { noteRects = next }
        }
    }

    /// Resolve: the note leaves the canvas (the design keeps no copy).
    @discardableResult
    func resolveNote(_ id: UUID) -> Task<Void, Never>? {
        guard let actions = referenceActions else { return nil }
        return Task {
            do {
                try await actions.removeNote(designID, id)
                if openNote == id { openNote = nil }
                threadNotes.removeAll { $0.id == id }
            } catch {
                actions.report("Couldn't remove the note: \(error)")
            }
            await refreshNotes()
        }
    }
}
