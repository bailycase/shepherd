import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

/// "Up next" above the composer (MobileQueue, MobileQueueMenu, MobileSteer, iPadQueue boards):
/// the messages the host holds while pi works, steering ones first. A queued row swipes for
/// Edit and Delete and long-presses for Steer now, Edit, Move to top and Delete; a steering row
/// has Back to the queue. The ••• menu steers or sends everything, picks how the queue goes when
/// the turn ends, and clears it. Every change goes to the host (`NativeThreadStore`'s queue
/// actions), which every device viewing the agent shares.
struct QueueSection: View {
    let store: NativeThreadStore
    let state: ComposerState
    let enabled: Bool
    @ScaledMetric(relativeTo: .body) private var rowsMaxHeight = MobileLayout.queueRowsMaxHeight
    @Environment(\.composerMaxHeight) private var composerMaxHeight

    var body: some View {
        let rows = state.rows
        if !rows.isEmpty {
            let running = store.running
            NWTouchQueueCard(count: store.queue.count, paused: store.queuePaused) {
                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        QueueRowView(row: row, first: row.id == rows.first?.id, steerLabel: NativeQueueStack.steerLabel(running: running),
                                     enabled: enabled, actions: actions)
                    }
                }
                .fittedScroll(maxHeight: min(rowsMaxHeight, composerMaxHeight * MobileLayout.queueShare))
            } options: {
                options(running: running)
            }
            .nwTransition(.list)
            .sheet(item: Binding(get: { state.editing }, set: { if $0 == nil { closeEditor(save: false) } })) { message in
                QueueEditorSheet(number: (state.queuedIndex(message.id) ?? 0) + 1, text: Binding(get: { state.editText }, set: { state.editText = $0 }),
                                 save: { closeEditor(save: true) }, cancel: { closeEditor(save: false) })
            }
        }
    }

    private var actions: QueueRowActions {
        let store = store
        let state = state
        return QueueRowActions(
            steer: { id in Task { await store.running ? store.steerQueued([id]) : store.sendQueuedNow([id]) } },
            back: { id in Task { await store.unsteer(id) } },
            edit: { id in
                guard let message = state.message(id) else { return }
                state.editText = message.text
                state.editing = message
                Task { await store.holdQueued(id, true) }
            },
            moveToTop: { id in Task { await store.moveQueued(id, to: 0) } },
            delete: { id in
                Task {
                    if let removed = await store.deleteQueued(id) { state.deleted(removed.message, index: removed.index) }
                }
            },
            undo: { rowID in
                guard let undo = state.takeUndo(rowID) else { return }
                Task { await store.restoreQueued(undo.messages, at: undo.index) }
            })
    }

    @ViewBuilder private func options(running: Bool) -> some View {
        let queued = state.queuedIDs
        if !queued.isEmpty {
            Button(running ? "Steer all now" : "Send all now", systemImage: "arrow.turn.down.right") {
                Task { await running ? store.steerQueued(queued) : store.sendQueuedNow(queued) }
            }
        }
        if store.queueMode != nil || store.supports("queue") {
            Picker(selection: Binding(get: { store.queueMode ?? .oneAtATime },
                                      set: { mode in Task { await store.setQueueMode(mode) } })) {
                ForEach(NativeQueueStack.modes, id: \.mode) { choice in
                    Text(choice.title).tag(choice.mode)
                }
            } label: {
                Text("When the turn ends, send")
            }
            .pickerStyle(.menu)
        }
        if !queued.isEmpty {
            Divider()
            Button("Clear the queue", systemImage: "trash", role: .destructive) {
                Task { state.cleared(await store.clearQueue()) }
            }
        }
    }

    private func closeEditor(save: Bool) {
        guard let message = state.editing else { return }
        let text = state.editText
        state.editing = nil
        Task {
            if save, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text != message.text {
                await store.editQueued(message.id, text: text)
            } else {
                await store.holdQueued(message.id, false)
            }
        }
    }
}

/// What a row can do; closures stay out of the rows' equality.
struct QueueRowActions {
    var steer: (UUID) -> Void
    var back: (UUID) -> Void
    var edit: (UUID) -> Void
    var moveToTop: (UUID) -> Void
    var delete: (UUID) -> Void
    var undo: (String) -> Void
}

/// One row: a queued message with its swipe actions and long-press menu, a steering one with
/// Back to the queue, or an Undo row.
private struct QueueRowView: View, Equatable {
    let row: NativeQueueStackRow
    let first: Bool
    let steerLabel: String
    let enabled: Bool
    let actions: QueueRowActions

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.row == rhs.row && lhs.first == rhs.first && lhs.steerLabel == rhs.steerLabel && lhs.enabled == rhs.enabled
    }

    var body: some View {
        let kind: NWTouchQueueRow.Kind = switch row.kind {
        case .steering: .steering
        case .queued(let number): .queued(number: number)
        case .deleted: .deleted
        case .cleared(let count): .cleared(count: count)
        }
        let id = row.message
        NWTouchQueueRow(row.text, images: row.images.count, kind: kind, held: row.held,
                        back: id.flatMap { id in enabled ? { actions.back(id) } : nil },
                        undo: row.message == nil && enabled ? { actions.undo(row.id) } : nil)
            .overlay(alignment: .top) { if !first { NWHairline() } }
            .modifier(QueuedRowActions(row: row, steerLabel: steerLabel, enabled: enabled, actions: actions))
    }
}

private struct QueuedRowActions: ViewModifier {
    let row: NativeQueueStackRow
    let steerLabel: String
    let enabled: Bool
    let actions: QueueRowActions

    func body(content: Content) -> some View {
        if row.isQueued, enabled, let id = row.message {
            content
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button("Delete", systemImage: "trash", role: .destructive) { actions.delete(id) }
                    Button("Edit", systemImage: "pencil") { actions.edit(id) }
                        .tint(Color.nw.textTertiary)
                }
                .contextMenu {
                    Button(steerLabel, systemImage: "arrow.turn.down.right") { actions.steer(id) }
                    Button("Edit", systemImage: "pencil") { actions.edit(id) }
                    if row.canMoveToTop {
                        Button("Move to top", systemImage: "arrow.up.to.line") { actions.moveToTop(id) }
                    }
                    Divider()
                    Button("Delete", systemImage: "trash", role: .destructive) { actions.delete(id) }
                }
                .accessibilityAction(named: steerLabel) { actions.steer(id) }
                .accessibilityAction(named: "Edit") { actions.edit(id) }
                .accessibilityAction(named: "Delete") { actions.delete(id) }
        } else {
            content
        }
    }
}

/// The editor for a queued message (the pencil, or Edit in its menu): a sheet with the text,
/// Cancel and Save. The host holds the message while it is open, so it never goes mid-edit.
private struct QueueEditorSheet: View {
    let number: Int
    @Binding var text: String
    let save: () -> Void
    let cancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            TextField("Message", text: $text, axis: .vertical)
                .font(.nw(.body))
                .lineLimit(MobileLayout.queueEditorLines...)
                .focused($focused)
                .padding(MobileLayout.gutter)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color.nw.bgWindow)
                .navigationTitle("Queued \(number)")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: cancel) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save", action: save)
                            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
    }
}
