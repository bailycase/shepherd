import SwiftUI
import AppKit
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

// "Up next" (Queue & steer boards): the messages sent while pi works, above the composer card,
// until pi takes them. The host holds the queue (`NativeThreadStore.queue`); this is the stack
// the composer draws of it, and what only this view knows: the editor, Undo rows, expansion,
// collapse, a drag, and which row is hovered.

/// One row of the stack as it draws.
struct QueueRowModel: Equatable, Identifiable {
    enum Kind: Equatable {
        /// Waiting; `number` is its place in the order it goes (1 is next).
        case queued(number: Int)
        /// Handed to pi, to read once its current tool calls finish.
        case steering
        /// Open in the editor, in its place.
        case editing(number: Int)
        /// Undo, where a message was deleted.
        case deleted(String)
        /// Undo, where the queue was cleared of this many messages.
        case cleared(Int)
        /// "Show N more", or "Show fewer" once expanded.
        case more(hidden: Int, expanded: Bool)
    }

    /// A message's id: a message and the Undo row it leaves are one view, cross-fading in place.
    let id: String
    var kind: Kind
    var message: NativeQueuedMessage?
    var attachments: [NWQueueAttachment] = []

    /// A message (not an Undo row or "Show more"): it takes keyboard focus.
    var isMessage: Bool {
        switch kind {
        case .queued, .steering, .editing: true
        default: false
        }
    }

    /// Waiting its turn (not steering): it can move, and it counts in the order.
    var isQueued: Bool {
        switch kind {
        case .queued, .editing: true
        default: false
        }
    }
}

/// How the stack lays out the queue: pure, so every rule is a unit test.
enum QueueStackLayout {
    /// The "Show N more" row's id.
    static let moreID = "queue.more"

    /// A deleted message, or a cleared queue, whose Undo row stands where it was.
    struct Undo: Equatable, Identifiable {
        let id: String
        let messages: [NativeQueuedMessage]
        /// Where the messages return among the queued ones.
        let index: Int
        let cleared: Bool
    }

    /// Where a dragged message would land.
    struct Drop: Equatable {
        /// The drop line sits before row `boundary` of the stack's rows (after the last when it
        /// equals their count).
        let boundary: Int
        /// The message's new place among the queued messages (0 goes first).
        let index: Int
    }

    /// Steering messages first, then the queued ones numbered in the order they go, with each
    /// Undo row back where its messages were. Past `shortStackLimit` rows only the first
    /// `longStackShown` show, then "Show N more" (an open editor further down shows them all);
    /// expanded, every row shows, then "Show fewer".
    static func rows(queue: [NativeQueuedMessage], undo: [Undo], editing: UUID? = nil, expanded: Bool = false,
                     attachments: (NativeQueuedMessage) -> [NWQueueAttachment] = { _ in [] }) -> [QueueRowModel] {
        func row(_ message: NativeQueuedMessage, _ kind: QueueRowModel.Kind) -> QueueRowModel {
            QueueRowModel(id: message.id.uuidString, kind: kind, message: message, attachments: attachments(message))
        }
        func placeholder(_ undo: Undo) -> QueueRowModel {
            QueueRowModel(id: undo.id, kind: undo.cleared ? .cleared(undo.messages.count) : .deleted(undo.messages.first?.text ?? ""))
        }
        var rows = queue.filter { $0.state == .steering }.map { row($0, .steering) }
        let present = Set(queue.map(\.id.uuidString))
        var pending = undo.enumerated().filter { !present.contains($0.element.id) }
            .sorted { ($0.element.index, $0.offset) < ($1.element.index, $1.offset) }.map(\.element)
        for (index, message) in queue.filter({ $0.state == .queued }).enumerated() {
            while let next = pending.first, next.index <= index {
                rows.append(placeholder(next))
                pending.removeFirst()
            }
            rows.append(row(message, message.id == editing ? .editing(number: index + 1) : .queued(number: index + 1)))
        }
        rows += pending.map(placeholder)

        guard rows.count > NWQueueMetrics.shortStackLimit else { return rows }
        let shown = NWQueueMetrics.longStackShown
        let editorHidden = rows.dropFirst(shown).contains { if case .editing = $0.kind { true } else { false } }
        if expanded || editorHidden {
            return rows + [QueueRowModel(id: moreID, kind: .more(hidden: 0, expanded: true))]
        }
        return Array(rows.prefix(shown)) + [QueueRowModel(id: moreID, kind: .more(hidden: rows.count - shown, expanded: false))]
    }

    /// Where a queued message dragged `translation` points from its row lands: past the middle
    /// of a neighbour, it takes the neighbour's side. Never above the steering messages, and
    /// nil when it would stay where it is.
    static func drop(rows: [QueueRowModel], moving id: String, translation: CGFloat,
                     rowHeight: CGFloat = NWQueueMetrics.rowHeight) -> Drop? {
        let slots = rows.filter { if case .more = $0.kind { false } else { true } }
        guard let from = slots.firstIndex(where: { $0.id == id }), slots[from].isQueued else { return nil }
        let steering = slots.prefix { $0.kind == .steering }.count
        let center = (CGFloat(from) + 0.5) * rowHeight + translation
        let boundary = min(max(Int((center / rowHeight).rounded()), steering), slots.count)
        guard boundary != from, boundary != from + 1 else { return nil }
        return Drop(boundary: boundary, index: slots[..<boundary].count { $0.isQueued && $0.id != id })
    }
}

/// A key a focused queued message answers.
enum QueueRowKey: Equatable {
    /// ↑ ↓: the previous or next message.
    case previous, next
    /// ⌥↑ ⌥↓: move it.
    case moveUp, moveDown
    /// ⌫: delete it (its Undo row takes its place).
    case delete
    /// ↩: edit it.
    case edit
    /// ⌘↩ (`alternateSend`): steer it in (send it now while pi is idle).
    case steer
    /// Esc or ⇥: back to the composer's field.
    case leave

    /// The key a press is, if the row answers it.
    init?(_ press: KeyPress, alternateSend: KeyChord) {
        self.init(key: press.key, modifiers: press.modifiers, alternateSend: alternateSend)
    }

    init?(key: KeyEquivalent, modifiers: EventModifiers, alternateSend: KeyChord) {
        if alternateSend.matches(key: key, modifiers: modifiers) { self = .steer; return }
        let chord = modifiers.intersection([.command, .shift, .option, .control])
        switch key {
        case .upArrow where chord.isEmpty: self = .previous
        case .downArrow where chord.isEmpty: self = .next
        case .upArrow where chord == .option: self = .moveUp
        case .downArrow where chord == .option: self = .moveDown
        case .delete where chord.isEmpty, .deleteForward where chord.isEmpty: self = .delete
        case .return where chord.isEmpty: self = .edit
        case .escape, .tab: self = .leave
        default: return nil
        }
    }
}

/// Where keyboard focus goes after a row handled a key.
enum QueueFocus: Equatable {
    case row(String)
    /// The composer's field.
    case composer
    /// The editor that just opened takes it.
    case editor
}

/// The stack's own state, around the store's queue. The composer owns it (`@State`) and hands
/// it every change of the store's queue (`update`); actions change what shows at once and ask
/// the store, whose own change lands in the same turn.
@MainActor
@Observable
final class QueueStackState {
    private(set) var rows: [QueueRowModel] = []
    /// Every message in the queue, steering ones included: the header's count.
    private(set) var count = 0
    /// The queued messages (not steering), for "Queued 2 of 3".
    private(set) var queuedCount = 0
    var collapsed = false
    private(set) var expanded = false
    /// The message open in the editor, and the editor's text.
    private(set) var editing: UUID?
    var draft = ""
    private(set) var undo: [QueueStackLayout.Undo] = []
    /// The row a drag lifted, how far it has moved, and where it would land.
    private(set) var dragging: String?
    private(set) var translation: CGFloat = 0
    private(set) var drop: QueueStackLayout.Drop?
    /// The lifted row's slot when the drag began.
    @ObservationIgnored private var dragFrom: Int?

    @ObservationIgnored private var queue: [NativeQueuedMessage] = []
    @ObservationIgnored private var images: (UUID) -> [NativeImage] = { _ in [] }
    /// Messages this stack deleted or cleared that the store may still list for a moment.
    @ObservationIgnored private var removing: Set<UUID> = []
    @ObservationIgnored private var hovers: [String: MessageHover] = [:]
    @ObservationIgnored private var deadlines: [String: ContinuousClock.Instant] = [:]
    @ObservationIgnored private var thumbnails: [UUID: [Image?]] = [:]

    /// Something to show: a message, or an Undo row.
    var isVisible: Bool { !rows.isEmpty }

    /// The queue as the store has it now. `images` are the ones this Mac sent with a message
    /// (`NativeThreadStore.queuedImages`), for the rows' thumbnails.
    func update(_ queue: [NativeQueuedMessage], images: @escaping (UUID) -> [NativeImage] = { _ in [] }) {
        self.queue = queue
        self.images = images
        let present = Set(queue.lazy.filter { !self.removing.contains($0.id) }.map(\.id.uuidString))
        // A message back in the queue (Undo from another Mac, or a delete the host refused)
        // takes its Undo row's place.
        let before = undo.count
        undo.removeAll { entry in entry.messages.contains { present.contains($0.id.uuidString) } }
        if undo.count != before { deadlines = deadlines.filter { id, _ in undo.contains { $0.id == id } } }
        if let editing, !queue.contains(where: { $0.id == editing && $0.state == .queued }) { self.editing = nil }
        if let dragging, !queue.contains(where: { $0.id.uuidString == dragging && $0.state == .queued }) { endDrag() }
        if queue.isEmpty, undo.isEmpty, expanded { expanded = false }
        let live = Set(queue.map(\.id))
        if thumbnails.keys.contains(where: { !live.contains($0) }) { thumbnails = thumbnails.filter { live.contains($0.key) } }
        derive()
    }

    private func derive() {
        let shown = queue.filter { !removing.contains($0.id) }
        let rows = QueueStackLayout.rows(queue: shown, undo: undo, editing: editing, expanded: expanded, attachments: attachments)
        if rows != self.rows { self.rows = rows }
        if shown.count != count { count = shown.count }
        let queued = shown.count { $0.state == .queued }
        if queued != queuedCount { queuedCount = queued }
    }

    /// A message's chips: its images' names, with the thumbnails this Mac has (decoded once).
    private func attachments(_ message: NativeQueuedMessage) -> [NWQueueAttachment] {
        guard !message.images.isEmpty else { return [] }
        let decoded = thumbnails[message.id] ?? {
            let value = images(message.id).map { image in NSImage(data: image.data).map { Image(nsImage: $0) } }
            thumbnails[message.id] = value
            return value
        }()
        return message.images.enumerated().map { index, image in
            NWQueueAttachment(id: "\(message.id.uuidString)/\(index)", name: image.name ?? "Image",
                              thumbnail: decoded.indices.contains(index) ? decoded[index] : nil)
        }
    }

    /// The row's pointer state; the row reads it, so a hover redraws only that row.
    func hover(_ id: String) -> MessageHover {
        if let hover = hovers[id] { return hover }
        let hover = MessageHover()
        hovers[id] = hover
        return hover
    }

    private var visible: [NativeQueuedMessage] { queue.filter { !removing.contains($0.id) } }

    // MARK: Actions

    /// Opens the editor on a queued message; it keeps its place, and the host holds the queue
    /// while it is open (the view renews the hold).
    func edit(_ id: UUID, store: NativeThreadStore) {
        guard let message = visible.first(where: { $0.id == id && $0.state == .queued }) else { return }
        if let open = editing, open != id { cancelEdit(store: store) }
        draft = message.text
        editing = id
        derive()
    }

    /// ↑ in an empty composer: the last queued message.
    @discardableResult
    func editLast(store: NativeThreadStore) -> Bool {
        guard let last = visible.last(where: { $0.state == .queued }) else { return false }
        edit(last.id, store: store)
        return true
    }

    func saveEdit(store: NativeThreadStore) {
        guard let id = editing else { return }
        let text = draft
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        editing = nil
        let changed = queue.first { $0.id == id }?.text != text
        if changed { NativeQueueRules.edit(id, text: text, in: &queue) }
        derive()
        Task.immediate { changed ? await store.editQueued(id, text: text) : await store.holdQueued(id, false) }
    }

    func cancelEdit(store: NativeThreadStore) {
        guard let id = editing else { return }
        editing = nil
        derive()
        Task.immediate { await store.holdQueued(id, false) }
    }

    /// Steer now while pi works; while it is idle (a paused queue) the message goes now.
    func steer(_ ids: [UUID], running: Bool, store: NativeThreadStore) {
        guard !ids.isEmpty else { return }
        if running {
            NativeQueueRules.steer(ids, in: &queue)
            derive()
            Task.immediate { await store.steerQueued(ids) }
        } else {
            queue.removeAll { ids.contains($0.id) }
            derive()
            Task.immediate { await store.sendQueuedNow(ids) }
        }
    }

    /// Steer all now (Send all now while pi is idle).
    func steerAll(running: Bool, store: NativeThreadStore) {
        steer(visible.filter { $0.state == .queued }.map(\.id), running: running, store: store)
    }

    /// Back to the queue: a steering message returns as #1.
    func unsteer(_ id: UUID, store: NativeThreadStore) {
        NativeQueueRules.unsteer(id, in: &queue)
        derive()
        Task.immediate { await store.unsteer(id) }
    }

    /// Deletes a queued message now; its Undo row takes its place for `queueUndoWindow`.
    func delete(_ id: UUID, store: NativeThreadStore) {
        guard let index = NativeQueueRules.queuedIndex(of: id, in: visible),
              let message = visible.first(where: { $0.id == id }) else { return }
        if editing == id { editing = nil }
        remember(QueueStackLayout.Undo(id: id.uuidString, messages: [message], index: index, cleared: false))
        removing.insert(id)
        derive()
        Task.immediate {
            await store.deleteQueued(id)
            removing.remove(id)
            update(store.queue, images: store.queuedImages)
        }
    }

    /// Clears the queue (steering messages stay), leaving one Undo row for all of it.
    func clear(store: NativeThreadStore) {
        let cleared = visible.filter { $0.state == .queued }
        guard !cleared.isEmpty else { return }
        editing = nil
        remember(QueueStackLayout.Undo(id: "cleared:" + UUID().uuidString, messages: cleared, index: 0, cleared: true))
        let ids = Set(cleared.map(\.id))
        removing.formUnion(ids)
        derive()
        Task.immediate {
            await store.clearQueue()
            removing.subtract(ids)
            update(store.queue, images: store.queuedImages)
        }
    }

    /// Puts what an Undo row stands for back where it was.
    func undo(_ id: String, store: NativeThreadStore) {
        guard let entry = undo.first(where: { $0.id == id }) else { return }
        undo.removeAll { $0.id == id }
        deadlines[id] = nil
        NativeQueueRules.insert(entry.messages, atQueuedIndex: entry.index, into: &queue)
        derive()
        Task.immediate { await store.restoreQueued(entry.messages, at: entry.index) }
    }

    private func remember(_ entry: QueueStackLayout.Undo) {
        undo.append(entry)
        deadlines[entry.id] = .now + AppLayout.queueUndoWindow
    }

    /// Closes the Undo rows whose window has passed. One under the pointer waits: its window
    /// starts over from now. Returns the next deadline, if any.
    @discardableResult
    func expireUndo(at now: ContinuousClock.Instant = .now) -> ContinuousClock.Instant? {
        var expired: Set<String> = []
        for entry in undo {
            guard let deadline = deadlines[entry.id] else { continue }
            if hovers[entry.id]?.hovering == true {
                deadlines[entry.id] = now + AppLayout.queueUndoWindow
            } else if deadline <= now {
                expired.insert(entry.id)
            }
        }
        if !expired.isEmpty {
            undo.removeAll { expired.contains($0.id) }
            for id in expired { deadlines[id] = nil }
            derive()
        }
        return deadlines.values.min()
    }

    /// ⌥↑ ⌥↓: one place up or down among the queued messages.
    @discardableResult
    func move(_ id: UUID, by offset: Int, store: NativeThreadStore) -> Bool {
        let queued = visible.filter { $0.state == .queued }
        guard let index = queued.firstIndex(where: { $0.id == id }) else { return false }
        let target = min(max(0, index + offset), queued.count - 1)
        guard target != index else { return false }
        NativeQueueRules.move(id, toQueuedIndex: target, in: &queue)
        derive()
        Task.immediate { await store.moveQueued(id, to: target) }
        return true
    }

    func toggleExpanded() {
        expanded.toggle()
        derive()
    }

    // MARK: Drag

    func drag(_ id: String, by translation: CGFloat) {
        if dragging != id {
            dragging = id
            dragFrom = slots.firstIndex { $0.id == id }
        }
        // The lifted row follows the pointer, up to half a row past the first and last rows.
        let from = CGFloat(dragFrom ?? 0), last = CGFloat(max(0, slots.count - 1)), half = NWQueueMetrics.rowHeight / 2
        self.translation = min(max(translation, -from * NWQueueMetrics.rowHeight - half), (last - from) * NWQueueMetrics.rowHeight + half)
        let drop = QueueStackLayout.drop(rows: rows, moving: id, translation: translation)
        if drop != self.drop { self.drop = drop }
    }

    /// Every row but "Show N more": the slots a drag moves through.
    private var slots: [QueueRowModel] { rows.filter { if case .more = $0.kind { false } else { true } } }

    /// How far a row steps aside while another is dragged: into the lifted row's slot, opening
    /// a gap where it would land.
    func shift(_ id: String) -> CGFloat {
        guard let drop, let from = dragFrom, dragging != id, let index = slots.firstIndex(where: { $0.id == id }) else { return 0 }
        if drop.boundary <= from, (drop.boundary..<from).contains(index) { return NWQueueMetrics.rowHeight }
        if drop.boundary > from + 1, (from + 1..<drop.boundary).contains(index) { return -NWQueueMetrics.rowHeight }
        return 0
    }

    /// The slot the drop line tops: the gap the rows opened.
    var dropSlot: Int? {
        guard let drop, let from = dragFrom else { return nil }
        return drop.boundary > from ? drop.boundary - 1 : drop.boundary
    }

    /// Lets go: the message takes its new place (the list moves around it), or returns to its own.
    func endDrag(_ id: String, at translation: CGFloat, store: NativeThreadStore) {
        let drop = QueueStackLayout.drop(rows: rows, moving: id, translation: translation)
        endDrag()
        guard let drop, let uuid = UUID(uuidString: id) else { return }
        NativeQueueRules.move(uuid, toQueuedIndex: drop.index, in: &queue)
        derive()
        Task.immediate { await store.moveQueued(uuid, to: drop.index) }
    }

    private func endDrag() {
        dragging = nil
        dragFrom = nil
        translation = 0
        drop = nil
    }

    // MARK: Keys

    /// Handles a key on a focused message and says where focus goes.
    func handle(_ key: QueueRowKey, on id: String, running: Bool, store: NativeThreadStore) -> QueueFocus {
        let messages = rows.filter(\.isMessage)
        guard let index = messages.firstIndex(where: { $0.id == id }), let uuid = UUID(uuidString: id) else { return .composer }
        let queued = messages[index].isQueued
        switch key {
        case .previous:
            return .row(messages[max(0, index - 1)].id)
        case .next:
            return index + 1 < messages.count ? .row(messages[index + 1].id) : .composer
        case .moveUp, .moveDown:
            if queued { move(uuid, by: key == .moveUp ? -1 : 1, store: store) }
            return .row(id)
        case .delete:
            guard queued else { return .row(id) }
            let neighbour = index + 1 < messages.count ? messages[index + 1].id : index > 0 ? messages[index - 1].id : nil
            delete(uuid, store: store)
            return neighbour.map(QueueFocus.row) ?? .composer
        case .edit:
            guard queued else { return .row(id) }
            edit(uuid, store: store)
            return .editor
        case .steer:
            if queued { steer([uuid], running: running, store: store) }
            return running ? .row(id) : .composer
        case .leave:
            return .composer
        }
    }
}

// MARK: Views

/// The stack itself: the composer puts it above the card while it has a row to show.
struct QueueStackView: View {
    @Bindable var state: QueueStackState
    let store: NativeThreadStore
    let running: Bool
    /// The thread has loaded since it came on screen: rows that arrive or leave move.
    let animated: Bool
    var focusedRow: FocusState<String?>.Binding
    let focusComposer: () -> Void

    var body: some View {
        let rows = state.rows
        let keys = KeybindingsStore.shared
        let actions = QueueRowActions(state: state, store: store, running: running)
        NWQueueStack(count: state.count, paused: store.queuePaused ? (store.queueNotice ?? Self.pausedHelp) : nil,
                     collapsed: state.collapsed,
                     scrolls: rows.last?.kind == .more(hidden: 0, expanded: true) && rows.count - 1 > NWQueueMetrics.expandedMaxRows,
                     drop: state.dropSlot,
                     onToggle: { withNWAnimation(.disclosure) { state.collapsed.toggle() } }) {
            ForEach(rows) { row in
                QueueRowView(row: row, hover: state.hover(row.id), focused: focusedRow.wrappedValue == row.id, running: running,
                             lift: state.dragging == row.id ? state.translation : nil, shift: state.shift(row.id),
                             total: state.queuedCount, steerShortcut: keys.display(.alternateSend),
                             deleteShortcut: keys.display(.deleteQueued), draft: $state.draft, actions: actions)
                    .equatable()
                    // The row's keyboard focus sits behind it, not around it: its buttons are not
                    // inside the focused view, so they never draw a focus ring of their own. Like
                    // a button, a row takes focus from the keyboard (⇥ with keyboard navigation on).
                    .background {
                        if row.isMessage && !isEditing(row) {
                            Color.clear
                                .focusable(interactions: .activate)
                                .focusEffectDisabled()
                                .focused(focusedRow, equals: row.id)
                                .onKeyPress(phases: .down) { press in
                                    guard let key = QueueRowKey(press, alternateSend: keys.chord(for: .alternateSend)) else { return .ignored }
                                    move(focus: state.handle(key, on: row.id, running: running, store: store))
                                    return .handled
                                }
                                .accessibilityHidden(true)
                        }
                    }
                    .zIndex(state.dragging == row.id ? 1 : 0)
                    .nwTransition(.list, insertion: .bottom, removal: .top)
            }
        } options: {
            QueueOptions(running: running, hasQueued: state.queuedCount > 0, mode: store.queueMode ?? .all,
                         steerAll: { state.steerAll(running: running, store: store) },
                         setMode: { mode in Task.immediate { await store.setQueueMode(mode) } },
                         clear: { state.clear(store: store) })
        }
        // Rows arriving, leaving, moving, and changing kind; a drag's own motion follows the pointer.
        .nwAnimation(.list, value: animated ? rows : nil)
        .task(id: state.undo.map(\.id)) {
            while let next = state.expireUndo() {
                do { try await Task.sleep(until: next, clock: .continuous) } catch { return }
            }
        }
        // The host holds the queue while the editor is open, and lets a hold lapse after two
        // minutes: renew it for as long as it stays open.
        .task(id: state.editing) {
            guard let id = state.editing else { return }
            while !Task.isCancelled {
                await store.holdQueued(id, true)
                do { try await Task.sleep(for: AppLayout.queueHoldRenewal) } catch { return }
            }
        }
    }

    static let pausedHelp = "The queue waits for you: send it, steer it in, or send a new message."

    private func isEditing(_ row: QueueRowModel) -> Bool {
        if case .editing = row.kind { true } else { false }
    }

    private func move(focus: QueueFocus) {
        switch focus {
        case .row(let id): focusedRow.wrappedValue = id
        case .composer:
            focusedRow.wrappedValue = nil
            focusComposer()
        case .editor: focusedRow.wrappedValue = nil
        }
    }
}

/// What a row's controls do, bound to the stack.
@MainActor
struct QueueRowActions {
    let state: QueueStackState
    let store: NativeThreadStore
    let running: Bool

    func steer(_ id: UUID) { state.steer([id], running: running, store: store) }
    func edit(_ id: UUID) { state.edit(id, store: store) }
    func delete(_ id: UUID) { state.delete(id, store: store) }
    func unsteer(_ id: UUID) { state.unsteer(id, store: store) }
    func move(_ id: UUID, by offset: Int) { state.move(id, by: offset, store: store) }
    func undo(_ id: String) { state.undo(id, store: store) }
    func save() { state.saveEdit(store: store) }
    func cancel() { state.cancelEdit(store: store) }
    func toggleExpanded() { withNWAnimation(.disclosure) { state.toggleExpanded() } }
    func drag(_ id: String, _ translation: CGFloat) { state.drag(id, by: translation) }
    func endDrag(_ id: String, _ translation: CGFloat) { state.endDrag(id, at: translation, store: store) }
}

/// One row of the stack. It compares by what it draws (the actions aside) and reads its own
/// hover, so the pointer crossing the stack redraws only the rows it enters and leaves.
struct QueueRowView: View, Equatable {
    let row: QueueRowModel
    let hover: MessageHover
    let focused: Bool
    let running: Bool
    /// How far a drag has moved this row.
    let lift: CGFloat?
    /// How far it steps aside for another row's drag.
    let shift: CGFloat
    /// Queued messages in all, for "Queued 2 of 3".
    let total: Int
    let steerShortcut: String
    let deleteShortcut: String
    let draft: Binding<String>
    let actions: QueueRowActions

    static func == (a: Self, b: Self) -> Bool {
        a.row == b.row && a.hover === b.hover && a.focused == b.focused && a.running == b.running
            && a.lift == b.lift && a.shift == b.shift && a.total == b.total && a.steerShortcut == b.steerShortcut && a.deleteShortcut == b.deleteShortcut
    }

    var body: some View {
        let _ = NWRenderProbe.tick("queue.row")
        VStack(spacing: 0) {
            switch row.kind {
            case .queued(let number):
                message(.queued(number: number))
            case .steering:
                message(.steering)
            case .editing(let number):
                NWQueueEditor(number: number, text: draft, onSave: actions.save, onCancel: actions.cancel)
            case .deleted(let text):
                NWQueueDeletedRow(deleted: text) { actions.undo(row.id) }
            case .cleared(let count):
                NWQueueDeletedRow(cleared: count) { actions.undo(row.id) }
            case .more(let hidden, let expanded):
                NWQueueMoreRow(hidden: hidden, expanded: expanded, action: actions.toggleExpanded)
            }
        }
        // The lifted row follows the pointer at once; its neighbours step aside on the list motion.
        .offset(y: lift ?? shift)
        .nwAnimation(.list, value: shift)
        .onHover { inside in if hover.hovering != inside { hover.hovering = inside } }
    }

    @ViewBuilder private func message(_ kind: NWQueueRow.Kind) -> some View {
        let id = row.message?.id
        let text = row.message?.text ?? ""
        let steering = kind == .steering
        NWQueueRow(text, attachments: row.attachments, kind: kind, hovering: hover.hovering, focused: focused, lifted: lift != nil,
                   actions: NWQueueRowActions(
                    steer: id.map { id in { actions.steer(id) } },
                    steerLabel: running ? "Steer now" : "Send now",
                    steerShortcut: steerShortcut,
                    edit: id.map { id in { actions.edit(id) } },
                    delete: id.map { id in { actions.delete(id) } },
                    deleteShortcut: deleteShortcut,
                    back: id.map { id in { actions.unsteer(id) } }),
                   drag: steering ? nil : NWQueueDrag(changed: { actions.drag(row.id, $0) }, ended: { actions.endDrag(row.id, $0) }))
            // The lifted row follows the pointer exactly.
            .transaction(value: lift) { if lift != nil { $0.animation = nil } }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel(kind, text: text))
            .accessibilityActions {
                if let id {
                    if steering {
                        Button("Back to the queue") { actions.unsteer(id) }
                    } else {
                        Button(running ? "Steer now" : "Send now") { actions.steer(id) }
                        Button("Edit") { actions.edit(id) }
                        Button("Delete") { actions.delete(id) }
                        Button("Move up") { actions.move(id, by: -1) }
                        Button("Move down") { actions.move(id, by: 1) }
                    }
                }
            }
    }

    private func accessibilityLabel(_ kind: NWQueueRow.Kind, text: String) -> String {
        switch kind {
        case .queued(let number): "Queued \(number) of \(total): \(text)"
        case .steering: "Steering: \(text), waiting for pi's current tool calls"
        }
    }
}

/// The ••• menu: Steer all now, how the queue goes when a turn ends, and Clear the queue.
private struct QueueOptions: View {
    let running: Bool
    let hasQueued: Bool
    let mode: NativeQueueMode
    let steerAll: () -> Void
    let setMode: (NativeQueueMode) -> Void
    let clear: () -> Void

    var body: some View {
        Button(action: steerAll) {
            Label(running ? "Steer all now" : "Send all now", systemImage: running ? "arrow.turn.down.right" : "arrow.up")
        }
        .disabled(!hasQueued)
        Divider()
        Section("When the turn ends, send") {
            Picker("When the turn ends, send", selection: Binding(get: { mode }, set: setMode)) {
                Text("One message per turn").tag(NativeQueueMode.oneAtATime)
                Text("Everything at once").tag(NativeQueueMode.all)
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        Divider()
        Button(role: .destructive, action: clear) { Label("Clear the queue", systemImage: "trash") }
            .disabled(!hasQueued)
    }
}
