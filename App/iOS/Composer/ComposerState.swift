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
/// slash matches. Kept per agent for the app's lifetime (`ComposerStates`),
/// so a thread shown again keeps its attachments. Rows and matches are derived here once per
/// change, never while drawing.
@MainActor
@Observable
final class ComposerState {
    private(set) var attachments: [ComposerAttachment] = []
    /// Why an image was refused, above the composer until the next attach or send.
    var attachmentError: String?
    private(set) var rows: [NativeQueueStackRow] = []
    /// The queued messages (not steering), in the order they go: Steer all and Clear.
    private(set) var queuedIDs: [UUID] = []
    /// The host's model catalog, once asked: whether the thread's model takes a thinking level.
    private(set) var models: ModelListing?
    /// The commands a "/…" draft matches.
    private(set) var matches: NativeSlashMatches?
    /// The subagent tray: collapsed to its header, and a long one showing every run.
    var trayCollapsed = false
    var trayExpanded = false
    /// pi's question folded on iPad (Hide the question): only that one stays folded.
    var questionHiding = NativeQuestionHiding()
    @ObservationIgnored private var undo: [NativeQueueUndo] = []
    @ObservationIgnored private var queue: [NativeQueuedMessage] = []
    @ObservationIgnored private var undoTasks: [String: Task<Void, Never>] = [:]

    /// How long a deleted message's Undo row stays.
    static let undoWindow: Duration = .seconds(5)

    @ObservationIgnored private var forgotten = false

    func forget() {
        forgotten = true
        queueEditor?.editing = nil
        queueEditor = nil
        clearAttachments()
        for task in undoTasks.values { task.cancel() }
        undoTasks = [:]
        undo = []
        queue = []
        models = nil
        matches = nil
        rebuild()
    }

    // MARK: Attachments

    var room: Int { NativeImagePreparation.room(attachments.count) }

    /// Adds images the picker loaded, resized for the send off the main thread (a camera photo
    /// takes a moment to decode and re-encode); refused ones say why.
    func attach(_ loaded: [(data: Data, name: String)]) async {
        attachmentError = nil
        for item in loaded {
            guard room > 0 else {
                attachmentError = NativeImagePreparation.Failure.full.description
                break
            }
            let (data, name) = item
            let thumbnailPixels = MobileLayout.attachmentThumbnailPixels
            let prepared = await Task.detached(priority: .userInitiated) { () -> Result<(NativeImage, UIImage?), Error> in
                Result {
                    let image = try NativeImagePreparation.prepare(data, name: name)
                    return (image, UIImage(data: image.data)?.preparingThumbnail(of: thumbnailPixels))
                }
            }.value
            guard !forgotten else { return }
            switch prepared {
            case .success(let (image, thumbnail)):
                // Another attach may have filled the message meanwhile.
                guard room > 0 else {
                    attachmentError = NativeImagePreparation.Failure.full.description
                    return
                }
                attachments.append(ComposerAttachment(image: image, thumbnail: thumbnail.map { Image(uiImage: $0) }))
            case .failure(let error):
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

    // The host has one hold bit, not per-window leases. Only one window may edit a queued
    // message in this thread; keep ownership until its save/release is acknowledged.
    @ObservationIgnored private weak var queueEditor: ComposerPresentation?

    @discardableResult
    func beginQueueEdit(_ message: NativeQueuedMessage, presentation: ComposerPresentation) -> Bool {
        guard !forgotten, queueEditor == nil else { return false }
        queueEditor = presentation
        presentation.editText = message.text
        presentation.editing = message
        return true
    }

    func closeQueueEdit(presentation: ComposerPresentation, store: NativeThreadStore, save: Bool) async {
        guard queueEditor === presentation, let message = presentation.editing else { return }
        let text = presentation.editText
        presentation.editing = nil
        defer { if queueEditor === presentation { queueEditor = nil } }
        if save, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text != message.text {
            await store.editQueued(message.id, text: text)
        } else {
            await store.holdQueued(message.id, false)
        }
    }

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
        let queued = queue.filter { $0.state == .queued }.map(\.id)
        if queued != queuedIDs { queuedIDs = queued }
    }

    func message(_ id: UUID?) -> NativeQueuedMessage? {
        id.flatMap { id in queue.first { $0.id == id } }
    }

    /// Where a queued message stands among the queued ones (the index Undo restores it to).
    func queuedIndex(_ id: UUID) -> Int? {
        NativeQueueRules.queuedIndex(of: id, in: queue)
    }

    // MARK: Models

    /// Asks the host's catalog (once per connection, `ComposerStates`) for the thinking chip.
    func loadModels(host: MobileHost?) async {
        guard !forgotten, let host, let listing = await ComposerStates.shared.listing(for: host), !forgotten else { return }
        if listing != models { models = listing }
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
    private var models: [UUID: (session: UUID?, listing: ModelListing)] = [:]
    private var forgottenHosts: Set<UUID> = []

    func state(for ref: AgentRef) -> ComposerState {
        if forgottenHosts.contains(ref.host) { return ComposerState() }
        if let state = states[ref] { return state }
        let state = ComposerState()
        states[ref] = state
        return state
    }

    func forget(host: UUID) {
        forgottenHosts.insert(host)
        for (ref, state) in states where ref.host == host { state.forget() }
        states = states.filter { $0.key.host != host }
        models[host] = nil
    }

    func models(host: UUID, session: UUID?) -> ModelListing? {
        guard let cached = models[host], cached.session == session else { return nil }
        return cached.listing
    }

    func setModels(_ listing: ModelListing, host: UUID, session: UUID?) {
        guard !forgottenHosts.contains(host) else { return }
        models[host] = (session, listing)
    }

    /// The host's catalog for this connection, asked when not yet known; nil while the host is
    /// offline or when it cannot answer.
    func listing(for host: MobileHost) async -> ModelListing? {
        if let cached = models(host: host.id, session: host.session) { return cached }
        let session = host.session
        guard let client = host.connectedClient, let listing = try? await client.listModels() else { return nil }
        guard host.session == session, host.connectedClient === client else { return nil }
        setModels(listing, host: host.id, session: session)
        return listing
    }
}
