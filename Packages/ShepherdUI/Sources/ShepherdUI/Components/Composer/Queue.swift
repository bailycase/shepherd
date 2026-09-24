import SwiftUI

// The queue (Queue & steer boards): messages sent while pi works stack above the composer in
// "Up next" until pi takes them, and each can be steered in now, edited, reordered or deleted.
// Value inputs only; the app owns the queue, the editor, the Undo rows, hover, focus and drags.

/// The queue's dimensions (Queue & steer boards).
public enum NWQueueMetrics {
    /// The "Up next" header, its glyph and its two buttons.
    public static let headerHeight: CGFloat = 32
    public static let headerGlyph: CGFloat = 12
    public static let headerButton: CGFloat = NW.Height.controlS
    /// A row: queued, steering, deleted. Fixed, like the composer's other parts (not scaled by
    /// Density).
    public static let rowHeight: CGFloat = 40
    /// "Show N more".
    public static let moreRowHeight: CGFloat = 32
    /// A queued row's number; a steering row has its bare spinner in its place, so its text
    /// starts a little further left.
    public static let numberSize: CGFloat = 18
    public static let spinnerSize: CGFloat = 14
    /// The grip's slot, and its six dots.
    public static let gripSize = CGSize(width: 8, height: 14)
    public static let gripDot: CGFloat = 2.2
    /// A row's icon buttons, and the slot that always holds three of them, so hovering never
    /// re-truncates the text.
    public static let actionSize: CGFloat = NWComposerMetrics.chipHeight
    public static let actionsWidth: CGFloat = 3 * actionSize + 2 * NW.Space.xxs
    /// A row's attachment chips (`NWAttachmentChip` `.compact`).
    public static let chipHeight: CGFloat = 22
    public static let chipThumbnail: CGFloat = 16
    public static let chipThumbnailRadius: CGFloat = 3
    /// The Deleted and Show-more rows start under the number column.
    public static let secondaryInset: CGFloat = 34
    /// The trash glyph of a Deleted row.
    public static let deletedGlyph: CGFloat = 12
    /// The edit field: its padding, its lines, and Geist 13 at the board's 1.5 line height.
    public static let editorPadding = EdgeInsets(top: NW.Space.m, leading: 10, bottom: NW.Space.m, trailing: 10)
    public static let editorMaxLines = 6
    public static let editorLineSpacing: CGFloat = 3
    /// The Send menu (right-click or hold Send while pi works).
    public static let sendMenuWidth: CGFloat = 268
    public static let sendMenuRowPadding = EdgeInsets(top: NW.Space.m, leading: 10, bottom: NW.Space.m, trailing: 10)
    public static let sendMenuGlyph: CGFloat = 14
    /// The glyph and the keys sit this much lower, level with the title.
    public static let sendMenuTitleInset: CGFloat = 1
    /// Up to this many rows the stack shows them all; past it, the first `longStackShown` and
    /// "Show N more", so the thread keeps its room.
    public static let shortStackLimit = 3
    public static let longStackShown = 2
    /// An expanded stack shows this many rows, then scrolls inside.
    public static let expandedMaxRows = 6
    /// A lifted row leans this far while it is dragged.
    public static let liftTilt: Double = -1
    /// A lifted row's card sits this far right of its slot (leading) and reaches this far past
    /// the stack's trailing edge (trailing): lifted out of the stack.
    public static let liftInset = EdgeInsets(top: 0, leading: 22, bottom: 0, trailing: 14)
}

// MARK: Glyphs

/// The queue's glyph (Queue & steer boards): a line, then two indented lines with a play mark
/// before them. Stroked at the board's weight at any size, in the foreground style.
public struct NWQueueGlyph: View {
    let size: CGFloat

    public init(size: CGFloat = NWQueueMetrics.headerGlyph) { self.size = size }

    public var body: some View {
        let line = size * 1.5 / 16
        ZStack {
            NWQueueGlyphLines().stroke(style: StrokeStyle(lineWidth: line, lineCap: .round))
            NWQueueGlyphMark().fill()
            NWQueueGlyphMark().stroke(style: StrokeStyle(lineWidth: line, lineJoin: .round))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The glyph's lines on the board's 16-unit grid.
private struct NWQueueGlyphLines: Shape {
    func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height) / 16
        var path = Path()
        for (from, to, y) in [(2.0, 14.0, 4.0), (6, 14, 8), (6, 14, 12)] {
            path.move(to: CGPoint(x: rect.minX + from * unit, y: rect.minY + y * unit))
            path.addLine(to: CGPoint(x: rect.minX + to * unit, y: rect.minY + y * unit))
        }
        return path
    }
}

private struct NWQueueGlyphMark: Shape {
    func path(in rect: CGRect) -> Path {
        let unit = min(rect.width, rect.height) / 16
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + 2 * unit, y: rect.minY + 7 * unit))
        path.addLine(to: CGPoint(x: rect.minX + 4.2 * unit, y: rect.minY + 8.5 * unit))
        path.addLine(to: CGPoint(x: rect.minX + 2 * unit, y: rect.minY + 10 * unit))
        path.closeSubpath()
        return path
    }
}

/// The drag handle of a queued row: six dots in a 2×3 grid, `textTertiary`.
public struct NWGripGlyph: View {
    public init() {}

    public var body: some View {
        NWGripDots()
            .fill(Color.nw.textTertiary)
            .frame(width: NWQueueMetrics.gripSize.width, height: NWQueueMetrics.gripSize.height)
            .accessibilityHidden(true)
    }
}

private struct NWGripDots: Shape {
    func path(in rect: CGRect) -> Path {
        let radius = NWQueueMetrics.gripDot / 2
        var path = Path()
        for x in [2.0, 6.0] {
            for y in [3.0, 7.0, 11.0] {
                path.addEllipse(in: CGRect(x: rect.minX + x - radius, y: rect.minY + y - radius,
                                           width: 2 * radius, height: 2 * radius))
            }
        }
        return path
    }
}

/// A queued message's place in the order it goes (1 is next): mono 10.5 in an 18pt ring. The
/// number is the order, not a count; it rolls when the order changes.
public struct NWQueueNumber: View {
    let number: Int

    public init(_ number: Int) { self.number = number }

    public var body: some View {
        Text("\(number)")
            .font(.nwMono(10.5))
            .foregroundStyle(.nw.textSecondary)
            .monospacedDigit()
            .nwContentTransition(.numeric())
            .nwComponentAnimation(.content, value: number)
            .frame(width: NWQueueMetrics.numberSize, height: NWQueueMetrics.numberSize)
            .nwBorder(.nw.lineStrong, in: Circle())
            .accessibilityHidden(true)
    }
}

// MARK: Stack

/// "Up next" (Queue & steer boards · QueueStack): a card directly above the composer card, in the
/// same column. A 32pt header (the queue glyph, "Up next", the count, the ••• options, Collapse),
/// then one row per message with a hairline between. A collapsed stack is its header alone.
/// Past `expandedMaxRows` rows it scrolls inside, so it never takes the thread's room. Rows keep
/// to the card's rounded corners, but a lifted row floats over the card and past its edges.
public struct NWQueueStack<Rows: View, Options: View>: View {
    let count: Int
    let paused: String?
    let collapsed: Bool
    let scrolls: Bool
    let drop: Int?
    let onToggle: () -> Void
    @ViewBuilder let rows: () -> Rows
    @ViewBuilder let options: () -> Options

    /// `count` is every message in the queue, steering ones included. `paused` says why the
    /// queue waits (its tooltip), when it does. `scrolls` caps the rows at `expandedMaxRows` and
    /// scrolls them, keeping the last row ("Show fewer") below.
    /// `drop` draws a drag's lantern drop line at the top of that row's slot, under the lifted
    /// row.
    public init(count: Int, paused: String? = nil, collapsed: Bool, scrolls: Bool = false, drop: Int? = nil,
                onToggle: @escaping () -> Void, @ViewBuilder rows: @escaping () -> Rows, @ViewBuilder options: @escaping () -> Options) {
        self.count = count
        self.paused = paused
        self.collapsed = collapsed
        self.scrolls = scrolls
        self.drop = drop
        self.onToggle = onToggle
        self.rows = rows
        self.options = options
    }

    public var body: some View {
        let nw = Color.nw
        let shape = RoundedRectangle(cornerRadius: NW.Radius.m)
        VStack(spacing: 0) {
            NWQueueHeader(count: count, paused: paused, collapsed: collapsed, onToggle: onToggle, options: options)
            if !collapsed {
                Group(subviews: rows()) { subviews in
                    // Scrolling, the last row ("Show fewer") stays under the rows that scroll.
                    let pinned = scrolls ? subviews.last : nil
                    VStack(spacing: 0) {
                        if scrolls {
                            ScrollView { list(subviews.dropLast(), first: subviews.first?.id) }
                                .frame(height: CGFloat(NWQueueMetrics.expandedMaxRows) * NWQueueMetrics.rowHeight)
                        } else {
                            list(subviews[...], first: subviews.first?.id)
                        }
                        if let pinned { pinned.overlay(alignment: .top) { NWHairline() } }
                    }
                }
                .overlay(alignment: .top) { NWHairline() }
                // The rows keep to the card's bottom corners; a lifted row floats past its edges.
                .clipShape(NWOutsideBottomCorners(radius: NW.Radius.m), style: FillStyle(eoFill: true))
                .nwTransition(.disclosure)
            }
        }
        .background(nw.bgRaised, in: shape)
        .nwBorder(nw.lineStrong, radius: NW.Radius.m)
        .accessibilityElement(children: .contain)
    }

    /// Rows, a hairline above each but the first, and the drop line under them.
    private func list(_ rows: SubviewsCollection.SubSequence, first: Subview.ID?) -> some View {
        VStack(spacing: 0) {
            ForEach(rows) { subview in
                subview.overlay(alignment: .top) {
                    if subview.id != first { NWHairline() }
                }
            }
        }
        .background(alignment: .top) {
            if let drop {
                NWDropIndicator(color: .nw.lantern)
                    .padding(.horizontal, NW.Space.m)
                    .offset(y: CGFloat(drop) * NWQueueMetrics.rowHeight - NWDropIndicator.thickness / 2)
                    .nwTransition(.hover)
            }
        }
        .nwAnimation(.hover, value: drop)
    }
}

/// Everything around the stack's rows but the two bottom corners the card rounds off (filled
/// even-odd): clipped to it, the rows keep to the card's shape while a lifted row, which a drag
/// keeps within half a row of them, floats past its edges with its shadow.
private struct NWOutsideBottomCorners: Shape {
    let radius: CGFloat
    static let reach = 2 * NWQueueMetrics.rowHeight

    func path(in rect: CGRect) -> Path {
        var path = Path(rect.insetBy(dx: -Self.reach, dy: -Self.reach))
        path.addRect(rect)
        path.addRoundedRect(in: rect, cornerRadii: RectangleCornerRadii(bottomLeading: radius, bottomTrailing: radius))
        return path
    }
}

private struct NWQueueHeader<Options: View>: View {
    let count: Int
    let paused: String?
    let collapsed: Bool
    let onToggle: () -> Void
    @ViewBuilder let options: () -> Options

    var body: some View {
        let nw = Color.nw
        HStack(spacing: NW.Space.m) {
            HStack(spacing: NW.Space.m) {
                NWQueueGlyph().foregroundStyle(nw.textTertiary)
                Text("Up next").font(.nwSans(12, .semibold)).foregroundStyle(nw.textSecondary)
                Text("\(count)").font(.nwMono(11)).foregroundStyle(nw.textTertiary).monospacedDigit()
                    .nwContentTransition(.numeric())
                    .nwComponentAnimation(.content, value: count)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Up next, \(count) \(count == 1 ? "message" : "messages")")
            .accessibilityAddTraits(.isHeader)
            if let paused {
                Text("Paused").font(.nw(.caption)).foregroundStyle(nw.textTertiary)
                    .help(paused)
                    .nwTransition(.content)
            }
            Spacer(minLength: NW.Space.m)
            NWOptionsMenu("Queue options", size: NWQueueMetrics.headerButton, content: options)
            Button(action: onToggle) {
                Image(systemName: "chevron.down")
                    .rotationEffect(.degrees(collapsed ? 180 : 0))
                    .nwComponentAnimation(.disclosure, value: collapsed)
            }
            .buttonStyle(.nwIcon(size: NWQueueMetrics.headerButton))
            .help(collapsed ? "Expand the queue" : "Collapse the queue")
            .accessibilityLabel(collapsed ? "Expand the queue" : "Collapse the queue")
        }
        .nwComponentAnimation(.content, value: paused != nil)
        .padding(.leading, NW.Space.l)
        .padding(.trailing, NW.Space.s)
        .frame(height: NWQueueMetrics.headerHeight)
    }
}

// MARK: Rows

/// An attachment a queued message carries: its image's name, and its thumbnail where this Mac
/// has the bytes (another client's show a photo glyph).
public struct NWQueueAttachment: Identifiable, Equatable {
    public var id: String
    public var name: String
    public var thumbnail: Image?

    public init(id: String, name: String, thumbnail: Image? = nil) {
        self.id = id
        self.name = name
        self.thumbnail = thumbnail
    }

    public static func == (a: Self, b: Self) -> Bool {
        a.id == b.id && a.name == b.name && (a.thumbnail == nil) == (b.thumbnail == nil)
    }
}

/// What a row's buttons do. A nil action hides its button.
public struct NWQueueRowActions {
    /// Steer now (Send now while pi is idle).
    public var steer: (() -> Void)?
    public var steerLabel: String
    public var steerShortcut: String?
    /// Opens the editor (the pencil, or a click on the text).
    public var edit: (() -> Void)?
    public var delete: (() -> Void)?
    public var deleteShortcut: String?
    /// A steering row's Back to the queue.
    public var back: (() -> Void)?

    public init(steer: (() -> Void)? = nil, steerLabel: String = "Steer now", steerShortcut: String? = nil,
                edit: (() -> Void)? = nil, delete: (() -> Void)? = nil, deleteShortcut: String? = nil, back: (() -> Void)? = nil) {
        self.steer = steer
        self.steerLabel = steerLabel
        self.steerShortcut = steerShortcut
        self.edit = edit
        self.delete = delete
        self.deleteShortcut = deleteShortcut
        self.back = back
    }
}

/// A drag of a row's grip: how far the pointer has moved, and where it let go.
public struct NWQueueDrag {
    public var changed: (CGFloat) -> Void
    public var ended: (CGFloat) -> Void

    public init(changed: @escaping (CGFloat) -> Void, ended: @escaping (CGFloat) -> Void) {
        self.changed = changed
        self.ended = ended
    }
}

/// A message in "Up next" (Queue & steer boards · QueueItem), 40pt:
///
/// - **Queued:** the grip (while hovered or focused; the only drag handle), its number, the
///   text on one line (a click edits it), its attachments, then a slot that always keeps room
///   for Steer now, Edit and Delete, built only while the row is hovered or focused.
/// - **Steering:** on `runningTint`, a spinner in the number's place, the "Steering" pill and
///   Back to the queue.
///
/// Hovered it is `bgHover`; with keyboard focus `bgSelected` and the focus ring drawn inside it,
/// since a ring outside would cover its neighbours. Lifted by a drag it floats on a card of its
/// own (`bgRaised` under `bgHover`, the popover's shadow), shifted right of its slot and past
/// the stack's trailing edge (`liftInset`).
public struct NWQueueRow: View {
    public enum Kind: Equatable, Sendable {
        /// Waiting; `number` is its place in the order it goes.
        case queued(number: Int)
        /// Handed to pi, to read once its current tool calls finish.
        case steering
    }

    let text: String
    let attachments: [NWQueueAttachment]
    let kind: Kind
    let hovering: Bool
    let focused: Bool
    let lifted: Bool
    let actions: NWQueueRowActions
    let drag: NWQueueDrag?

    public init(_ text: String, attachments: [NWQueueAttachment] = [], kind: Kind, hovering: Bool = false, focused: Bool = false,
                lifted: Bool = false, actions: NWQueueRowActions = NWQueueRowActions(), drag: NWQueueDrag? = nil) {
        self.text = text
        self.attachments = attachments
        self.kind = kind
        self.hovering = hovering
        self.focused = focused
        self.lifted = lifted
        self.actions = actions
        self.drag = drag
    }

    public var body: some View {
        let nw = Color.nw
        let steering = kind == .steering
        let active = hovering || focused || lifted
        HStack(spacing: NW.Space.m) {
            grip(shown: active && !steering && drag != nil)
            ZStack {
                switch kind {
                case .queued(let number):
                    NWQueueNumber(number).nwTransition(.content)
                case .steering:
                    ProgressView().progressViewStyle(.nwSpinner(size: NWQueueMetrics.spinnerSize, color: nw.running))
                        .nwTransition(.content)
                }
            }
            .frame(width: steering ? NWQueueMetrics.spinnerSize : NWQueueMetrics.numberSize, height: NWQueueMetrics.numberSize)
            label
            if !attachments.isEmpty {
                HStack(spacing: NW.Space.xs) {
                    ForEach(attachments) { NWAttachmentChip($0.name, thumbnail: $0.thumbnail, size: .compact) }
                }
                .layoutPriority(1)
            }
            ZStack(alignment: .trailing) {
                if steering {
                    HStack(spacing: NW.Space.xs) {
                        NWStatusPill(.running, label: "Steering", symbol: "arrow.turn.down.right")
                        if let back = actions.back {
                            iconButton("arrow.uturn.backward", "Back to the queue", action: back)
                        }
                    }
                    .nwTransition(.content)
                } else {
                    HStack(spacing: NW.Space.xxs) {
                        if active && !lifted {
                            if let steer = actions.steer { iconButton("arrow.turn.down.right", actions.steerLabel, shortcut: actions.steerShortcut, action: steer) }
                            if let edit = actions.edit { iconButton("pencil", "Edit", action: edit) }
                            if let delete = actions.delete { iconButton("trash", "Delete", shortcut: actions.deleteShortcut, action: delete) }
                        }
                    }
                    .frame(width: NWQueueMetrics.actionsWidth, alignment: .trailing)
                    .nwTransition(.content)
                }
            }
            .layoutPriority(1)
        }
        .nwComponentAnimation(.content, value: kind)
        .padding(.leading, NW.Space.m)
        .padding(.trailing, NW.Space.s)
        .frame(height: NWQueueMetrics.rowHeight)
        .frame(maxWidth: .infinity)
        .background { fill }
        .overlay {
            if focused && !lifted {
                RoundedRectangle(cornerRadius: NW.Radius.s).inset(by: NW.Space.xxs)
                    .strokeBorder(nw.focusRing, lineWidth: NW.Space.xxs)
                    .allowsHitTesting(false)
            }
        }
        .padding(.leading, lifted ? NWQueueMetrics.liftInset.leading : 0)
        .padding(.trailing, lifted ? -NWQueueMetrics.liftInset.trailing : 0)
        .rotationEffect(.degrees(lifted ? NWQueueMetrics.liftTilt : 0))
        .contentShape(Rectangle())
    }

    /// Clear at rest, `bgHover` under the pointer, `bgSelected` with focus, `runningTint` while
    /// steering; a lifted row is a floating card, still under the pointer.
    @ViewBuilder private var fill: some View {
        let nw = Color.nw
        if lifted {
            let card = RoundedRectangle(cornerRadius: NW.Radius.m)
            card.fill(nw.bgRaised)
                .overlay { card.fill(nw.bgHover) }
                .nwBorder(nw.lineStrong, radius: NW.Radius.m)
                .nwFloatShadow()
        } else {
            Rectangle()
                .fill(kind == .steering ? nw.runningTint : focused ? nw.bgSelected : hovering ? nw.bgHover : Color.clear)
                .nwAnimation(.hover, value: hovering)
        }
    }

    private func grip(shown: Bool) -> some View {
        NWGripGlyph()
            .opacity(shown ? 1 : 0)
            .nwAnimation(.hover, value: shown)
            .frame(width: NWQueueMetrics.gripSize.width, height: NWQueueMetrics.rowHeight)
            .contentShape(Rectangle())
            .pointerStyle(drag == nil || kind == .steering ? nil : lifted ? .grabActive : .grabIdle)
            .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .onChanged { value in drag?.changed(value.translation.height) }
                .onEnded { value in drag?.ended(value.translation.height) },
                     isEnabled: drag != nil && kind != .steering)
            .accessibilityHidden(true)
    }

    @ViewBuilder private var label: some View {
        let text = Text(text).font(.nwSans(13)).foregroundStyle(Color.nw.textPrimary)
            .lineLimit(1).truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
        if let edit = actions.edit, kind != .steering {
            Button(action: edit) { text.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .help("Edit")
        } else {
            text
        }
    }

    private func iconButton(_ symbol: String, _ label: String, shortcut: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(.nwIcon(size: NWQueueMetrics.actionSize))
            .nwHelp(label, shortcut: shortcut)
            .accessibilityLabel(label)
    }
}

/// A message the editor is open on (Queue & steer boards · QueueItem editing), in its place: its
/// number, then the text in a field with a lantern line and ring, and Cancel and Save. ↩ saves,
/// ⇧↩ adds a line, Esc cancels. Save is secondary: Send is the surface's primary action.
public struct NWQueueEditor: View {
    let number: Int
    @Binding var text: String
    let onSave: () -> Void
    let onCancel: () -> Void
    @FocusState private var focused: Bool
    /// The caret starts after the text, as the composer's does, rather than over all of it.
    @State private var selection: TextSelection?

    public init(number: Int, text: Binding<String>, onSave: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.number = number
        _text = text
        self.onSave = onSave
        self.onCancel = onCancel
    }

    private var canSave: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    public var body: some View {
        let nw = Color.nw
        let field = RoundedRectangle(cornerRadius: NW.Radius.s)
        HStack(alignment: .top, spacing: NW.Space.m) {
            NWQueueNumber(number)
            VStack(alignment: .trailing, spacing: NW.Space.m) {
                TextField(text: $text, selection: $selection, axis: .vertical) { Text("Queued message") }
                    .lineLimit(1...NWQueueMetrics.editorMaxLines)
                    .textFieldStyle(.plain)
                    .font(.nwSans(13))
                    .lineSpacing(NWQueueMetrics.editorLineSpacing)
                    .foregroundStyle(nw.textPrimary)
                    .tint(nw.lantern)
                    .autocorrectionDisabled()
                    .focused($focused)
                    .onKeyPress(.return, phases: .down) { press in
                        if press.modifiers.contains(.shift) { text += "\n"; return .handled }
                        if canSave { onSave() }
                        return .handled
                    }
                    .onKeyPress(.escape) { onCancel(); return .handled }
                    .padding(NWQueueMetrics.editorPadding)
                    .background(nw.bgRaised, in: field)
                    .nwBorder(nw.lantern, radius: NW.Radius.s)
                    .background {
                        RoundedRectangle(cornerRadius: NW.Radius.s + NWComposerMetrics.focusRing)
                            .inset(by: -NWComposerMetrics.focusRing).fill(nw.lanternTint)
                    }
                    .accessibilityLabel("Edit queued message \(number)")
                HStack(spacing: NW.Space.s) {
                    Button("Cancel", action: onCancel).buttonStyle(.nw(.ghost, size: .s))
                    Button("Save", action: onSave).buttonStyle(.nw(.secondary, size: .s)).disabled(!canSave)
                }
            }
        }
        .padding(.vertical, NW.Space.m)
        .padding(.leading, NW.Space.xxl)
        .padding(.trailing, NW.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(nw.bgWindow)
        .onAppear { focused = true }
        // Taking focus selects the whole field; the caret goes after the text instead.
        .onChange(of: focused) { _, focused in
            if focused { selection = TextSelection(insertionPoint: text.endIndex) }
        }
    }
}

/// Where a message was deleted, or the queue cleared (Queue & steer boards · QueueItem deleted):
/// the same 40pt, a trash glyph, "Deleted" and the struck-through text (or "Cleared 3
/// messages"), and Undo.
public struct NWQueueDeletedRow: View {
    let deleted: String?
    let cleared: Int
    let onUndo: () -> Void

    /// A deleted message.
    public init(deleted text: String, onUndo: @escaping () -> Void) {
        deleted = text
        cleared = 0
        self.onUndo = onUndo
    }

    /// A cleared queue.
    public init(cleared count: Int, onUndo: @escaping () -> Void) {
        deleted = nil
        cleared = count
        self.onUndo = onUndo
    }

    public var body: some View {
        let nw = Color.nw
        HStack(spacing: NW.Space.m) {
            Image(systemName: "trash")
                .font(.system(size: NWQueueMetrics.deletedGlyph, weight: .medium))
                .foregroundStyle(nw.textTertiary)
                .accessibilityHidden(true)
            Group {
                if let deleted {
                    Text("Deleted \(Text(deleted).strikethrough())")
                } else {
                    Text("Cleared \(cleared) \(cleared == 1 ? "message" : "messages")")
                }
            }
            .font(.nw(.ui, weight: .regular))
            .foregroundStyle(nw.textTertiary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Undo", action: onUndo).buttonStyle(.nwLink(font: .nw(.ui)))
        }
        .padding(.leading, NWQueueMetrics.secondaryInset)
        .padding(.trailing, NW.Space.l)
        .frame(height: NWQueueMetrics.rowHeight)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(deleted.map { "Deleted: \($0)" } ?? "Cleared \(cleared) queued messages")
        .accessibilityAction(named: "Undo", onUndo)
    }
}

/// "Show N more" under a long stack's first rows, or "Show fewer" once it is expanded.
public struct NWQueueMoreRow: View {
    let hidden: Int
    let expanded: Bool
    let action: () -> Void

    public init(hidden: Int, expanded: Bool, action: @escaping () -> Void) {
        self.hidden = hidden
        self.expanded = expanded
        self.action = action
    }

    public var body: some View {
        Button(expanded ? "Show fewer" : "Show \(hidden) more", action: action)
            .buttonStyle(.nwLink(font: .nwSans(12)))
            .padding(.leading, NWQueueMetrics.secondaryInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: NWQueueMetrics.moreRowHeight)
    }
}

// MARK: Send menu

/// A way to send a message while pi works (the Send menu's rows).
public struct NWSendOption: Identifiable, Equatable, Sendable {
    public enum Glyph: Equatable, Sendable {
        /// The queue's own glyph.
        case queue
        case symbol(String)
    }

    public var id: String
    public var title: String
    public var detail: String
    public var glyph: Glyph
    /// Its keys, as the store displays them ("↩", "⌘↩").
    public var shortcut: String

    public init(id: String, title: String, detail: String, glyph: Glyph, shortcut: String) {
        self.id = id
        self.title = title
        self.detail = detail
        self.glyph = glyph
        self.shortcut = shortcut
    }
}

/// The choice at send time (Queue & steer boards · SendMenu), opened by right-clicking or holding
/// Send while pi works: Queue and Steer now, each with what it does and its keys. 268pt on the
/// popover surface; ↑↓ move, ↩ chooses, Esc closes. Nothing about the choice is written under
/// the composer.
public struct NWSendMenu: View {
    let options: [NWSendOption]
    let onChoose: (NWSendOption) -> Void
    let onClose: () -> Void
    @State private var selection: Int
    @FocusState private var focused: Bool

    /// `highlighted` is the row ↩ would choose (the Return setting's).
    public init(options: [NWSendOption], highlighted: Int = 0, onChoose: @escaping (NWSendOption) -> Void,
                onClose: @escaping () -> Void) {
        self.options = options
        self.onChoose = onChoose
        self.onClose = onClose
        _selection = State(initialValue: highlighted)
    }

    public var body: some View {
        let nw = Color.nw
        VStack(alignment: .leading, spacing: NW.Space.xxs) {
            ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                NWMenuRow(highlighted: index == selection, alignment: .top, padding: NWQueueMetrics.sendMenuRowPadding,
                          action: { onChoose(option) }, onHover: { selection = index }) {
                    Group {
                        switch option.glyph {
                        case .queue: NWQueueGlyph(size: NWQueueMetrics.sendMenuGlyph)
                        case .symbol(let name):
                            Image(systemName: name).font(.system(size: NWQueueMetrics.sendMenuGlyph, weight: .medium))
                        }
                    }
                    .foregroundStyle(nw.textSecondary)
                    .frame(width: NWQueueMetrics.sendMenuGlyph, height: NWQueueMetrics.sendMenuGlyph)
                    .padding(.top, NWQueueMetrics.sendMenuTitleInset)
                    VStack(alignment: .leading, spacing: NW.Space.xxs) {
                        Text(option.title).font(.nwSans(13, .medium)).foregroundStyle(nw.textPrimary)
                        Text(option.detail).nwText(.caption).foregroundStyle(nw.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    NWKeycap(option.shortcut).padding(.top, NWQueueMetrics.sendMenuTitleInset)
                }
                .accessibilityLabel("\(option.title), \(option.detail)")
            }
        }
        .modifier(NWMenuSurface(width: NWQueueMetrics.sendMenuWidth))
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.downArrow) { selection = min(options.count - 1, selection + 1); return .handled }
        .onKeyPress(.upArrow) { selection = max(0, selection - 1); return .handled }
        .onKeyPress(.return) {
            if options.indices.contains(selection) { onChoose(options[selection]) }
            return .handled
        }
        .onKeyPress(.escape) { onClose(); return .handled }
        .onAppear { focused = true }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Send")
    }
}
