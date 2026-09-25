import SwiftUI
import UIKit
import ShepherdProtocol
import ShepherdRemote

/// An image waiting in the composer: what goes with the send, and its thumbnail.
struct ComposerAttachment: Identifiable {
    let id = UUID()
    let image: NativeImage
    let thumbnail: Image?
}

/// What only the composer knows about one thread, beside its `NativeThreadStore` (which holds
/// the draft and the host's queue): attachments, the Up next rows with their Undo places, the
/// open editor, and the slash matches. Kept per agent for the app's lifetime (`ComposerStates`),
/// so a thread shown again keeps its attachments. Rows and matches are derived here once per
/// change, never while drawing.
@MainActor
@Observable
final class ComposerState {
    private(set) var attachments: [ComposerAttachment] = []
    /// Why an image was refused, above the composer until the next attach or send.
    var attachmentError: String?
    private(set) var rows: [NativeQueueStackRow] = []
    /// A queued message open in the editor sheet, and the editor's text.
    var editing: NativeQueuedMessage?
    var editText = ""
    /// The model picker sheet is open.
    var choosingModel = false
    /// The commands a "/…" draft matches.
    private(set) var matches: NativeSlashMatches?
    @ObservationIgnored private var undo: [NativeQueueUndo] = []
    @ObservationIgnored private var queue: [NativeQueuedMessage] = []
    @ObservationIgnored private var undoTasks: [String: Task<Void, Never>] = [:]

    /// How long a deleted message's Undo row stays.
    static let undoWindow: Duration = .seconds(5)

    // MARK: Attachments

    var room: Int { NativeImagePreparation.room(attachments.count) }

    /// Adds images the picker loaded, resized for the send; refused ones say why.
    func attach(_ loaded: [(data: Data, name: String)]) {
        attachmentError = nil
        for item in loaded {
            guard room > 0 else {
                attachmentError = NativeImagePreparation.Failure.full.description
                break
            }
            do {
                let image = try NativeImagePreparation.prepare(item.data, name: item.name)
                let thumbnail = UIImage(data: image.data)?.preparingThumbnail(of: MobileLayout.attachmentThumbnailPixels)
                    .map { Image(uiImage: $0) }
                attachments.append(ComposerAttachment(image: image, thumbnail: thumbnail))
            } catch {
                attachmentError = String(describing: error)
            }
        }
    }

    func remove(_ id: UUID) {
        attachments.removeAll { $0.id == id }
    }

    func clearAttachments() {
        if !attachments.isEmpty { attachments = [] }
        attachmentError = nil
    }

    // MARK: Up next

    /// The host's queue changed (or this client's view of it).
    func update(queue: [NativeQueuedMessage]) {
        self.queue = queue
        rebuild()
    }

    /// A delete went to the host: its Undo row takes the message's place for a few seconds.
    func deleted(_ message: NativeQueuedMessage, index: Int) {
        keepUndo(NativeQueueUndo(messages: [message], index: index, cleared: false))
    }

    func cleared(_ messages: [NativeQueuedMessage]) {
        guard !messages.isEmpty else { return }
        keepUndo(NativeQueueUndo(messages: messages, index: 0, cleared: true))
    }

    /// Takes an Undo row away (Undo was chosen, or its time ran out); returns what it held.
    @discardableResult
    func takeUndo(_ id: String) -> NativeQueueUndo? {
        undoTasks.removeValue(forKey: id)?.cancel()
        guard let index = undo.firstIndex(where: { $0.id == id }) else { return nil }
        let taken = undo.remove(at: index)
        rebuild()
        return taken
    }

    private func keepUndo(_ item: NativeQueueUndo) {
        undo.removeAll { $0.id == item.id }
        undo.append(item)
        rebuild()
        undoTasks[item.id]?.cancel()
        undoTasks[item.id] = Task { [weak self] in
            try? await Task.sleep(for: Self.undoWindow)
            guard !Task.isCancelled else { return }
            self?.takeUndo(item.id)
        }
    }

    private func rebuild() {
        let rows = NativeQueueStack.rows(queue, undo: undo)
        if rows != self.rows { self.rows = rows }
    }

    func message(_ id: UUID?) -> NativeQueuedMessage? {
        id.flatMap { id in queue.first { $0.id == id } }
    }

    /// Where a queued message stands among the queued ones (the index Undo restores it to).
    func queuedIndex(_ id: UUID) -> Int? {
        NativeQueueRules.queuedIndex(of: id, in: queue)
    }

    // MARK: Slash commands

    func update(draft: String, commands: [NativeCommand]) {
        let matches = NativeSlashMatches(draft: draft, commands: commands)
        if matches != self.matches { self.matches = matches }
    }
}

/// One `ComposerState` per agent, for the app's lifetime.
@MainActor
final class ComposerStates {
    static let shared = ComposerStates()
    private var states: [AgentRef: ComposerState] = [:]
    /// Each host's model catalog (`listModels`), asked once per connection.
    private var models: [UUID: (session: UUID?, ids: [String])] = [:]

    func state(for ref: AgentRef) -> ComposerState {
        if let state = states[ref] { return state }
        let state = ComposerState()
        states[ref] = state
        return state
    }

    func models(host: UUID, session: UUID?) -> [String]? {
        guard let cached = models[host], cached.session == session else { return nil }
        return cached.ids
    }

    func setModels(_ ids: [String], host: UUID, session: UUID?) {
        models[host] = (session, ids)
    }
}
