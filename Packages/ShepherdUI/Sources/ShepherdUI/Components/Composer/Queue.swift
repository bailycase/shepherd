import SwiftUI

// The queue (Queue & steer boards): messages sent while pi works stack above the composer in
// "Up next" until pi takes them, and each can be steered in now, edited, reordered or deleted.
// Value inputs only; the app owns the queue, the editor, the Undo rows, hover, focus and drags.

/// The queue's dimensions (Queue & steer boards).
public enum SHQueueMetrics {
    /// The "Up next" header, its glyph and its two buttons.
    public static let headerHeight: CGFloat = 32
    public static let headerGlyph: CGFloat = 12
    public static let headerButton: CGFloat = SH.Height.controlS
    /// A row: queued, steering, deleted. Fixed, like the composer's other parts (not scaled by
    /// Density).
    public static let rowHeight: CGFloat = 40
    /// "Show N more".
    public static let moreRowHeight: CGFloat = 32
    /// A queued row's number; a steering row has its still steer glyph in its place (LiveText:
    /// waiting isn't working), so its text starts a little further left.
    public static let numberSize: CGFloat = 18
    public static let steerGlyph: CGFloat = 14
    /// The grip's slot, and its six dots.
    public static let gripSize = CGSize(width: 8, height: 14)
    public static let gripDot: CGFloat = 2.2
    /// A row's icon buttons, and the slot that always holds three of them, so hovering never
    /// re-truncates the text.
    public static let actionSize: CGFloat = SHComposerMetrics.chipHeight
    public static let actionsWidth: CGFloat = 3 * actionSize + 2 * SH.Space.xxs
    /// The first queued row while pi works draws Steer now as a labelled button that is always there,
    /// so the slot it reserves holds that button (whatever the text size makes it) and, beside it,
    /// the room Edit and Delete take on hover: never less, so hovering still re-truncates nothing.
    public static let editDeleteWidth: CGFloat = 2 * actionSize + SH.Space.xxs
    /// A row's attachment chips (`SHAttachmentChip` `.compact`).
    public static let chipHeight: CGFloat = 22
    public static let chipThumbnail: CGFloat = 16
    public static let chipThumbnailRadius: CGFloat = 3
    /// The Deleted and Show-more rows start under the number column.
    public static let secondaryInset: CGFloat = 34
    /// The trash glyph of a Deleted row.
    public static let deletedGlyph: CGFloat = 12
    /// The edit field: its padding, its lines, and Geist 13 at the board's 1.5 line height.
    public static let editorPadding = EdgeInsets(top: SH.Space.m, leading: 10, bottom: SH.Space.m, trailing: 10)
    public static let editorMaxLines = 6
    public static let editorLineSpacing: CGFloat = 3
    /// The Send menu (right-click or hold Send while pi works).
    public static let sendMenuWidth: CGFloat = 268
    public static let sendMenuRowPadding = EdgeInsets(top: SH.Space.m, leading: 10, bottom: SH.Space.m, trailing: 10)
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
public struct SHQueueGlyph: View {
    let size: CGFloat

    public init(size: CGFloat = SHQueueMetrics.headerGlyph) { self.size = size }

    public var body: some View {
        let line = size * 1.5 / 16
        ZStack {
            SHQueueGlyphLines().stroke(style: StrokeStyle(lineWidth: line, lineCap: .round))
            SHQueueGlyphMark().fill()
            SHQueueGlyphMark().stroke(style: StrokeStyle(lineWidth: line, lineJoin: .round))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The glyph's lines on the board's 16-unit grid.
private struct SHQueueGlyphLines: Shape {
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

private struct SHQueueGlyphMark: Shape {
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
public struct SHGripGlyph: View {
    public init() {}

    public var body: some View {
        SHGripDots()
            .fill(Color.sh.textTertiary)
            .frame(width: SHQueueMetrics.gripSize.width, height: SHQueueMetrics.gripSize.height)
            .accessibilityHidden(true)
    }
}

private struct SHGripDots: Shape {
    func path(in rect: CGRect) -> Path {
        let radius = SHQueueMetrics.gripDot / 2
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
public struct SHQueueNumber: View {
    let number: Int

    public init(_ number: Int) { self.number = number }

    public var body: some View {
        Text("\(number)")
            .font(.shMono(10.5))
            .foregroundStyle(.sh.textSecondary)
            .monospacedDigit()
            .shContentTransition(.numeric())
            .shComponentAnimation(.content, value: number)
            .frame(width: SHQueueMetrics.numberSize, height: SHQueueMetrics.numberSize)
            .shBorder(.sh.lineStrong, in: Circle())
            .accessibilityHidden(true)
    }
}

// MARK: Stack

/// "Up next" (Queue & steer boards · QueueStack): a card directly above the composer card, in the
/// same column. A 32pt header (the queue glyph, "Up next", the count, the ••• options, Collapse),
/// then one row per message with a hairline between. A collapsed stack is its header alone.
/// Past `expandedMaxRows` rows it scrolls inside, so it never takes the thread's room. Rows keep
/// to the card's rounded corners, but a lifted row floats over the card and past its edges.
/// Unframed, it draws no card of its own: it is Up next's section of the dock (`SHDockStack`),
/// under the subagents.
public struct SHQueueStack<Rows: View, Options: View>: View {
    let afterGoalCheck: Bool
    let count: Int
    let framed: Bool
    let paused: String?
    let collapsed: Bool
    let scrolls: Bool
    let drop: Int?
    let showsOptions: Bool
    let onToggle: () -> Void
    @ViewBuilder let rows: () -> Rows
    @ViewBuilder let options: () -> Options

    /// `showsOptions` false drops the ••• menu: a queue whose holder offers no options draws no empty menu.
    /// `count` is every message in the queue, steering ones included. `paused` says why the
    /// queue waits (its tooltip), when it does. `scrolls` caps the rows at `expandedMaxRows` and
    /// scrolls them, keeping the last row ("Show fewer") below.
    /// `drop` draws a drag's lantern drop line at the top of that row's slot, under the lifted
    /// row.
    public init(count: Int, paused: String? = nil, collapsed: Bool, scrolls: Bool = false, drop: Int? = nil, framed: Bool = true, afterGoalCheck: Bool = false,
                showsOptions: Bool = true,
                onToggle: @escaping () -> Void, @ViewBuilder rows: @escaping () -> Rows, @ViewBuilder options: @escaping () -> Options) {
        self.count = count
        self.showsOptions = showsOptions
        self.framed = framed
        self.afterGoalCheck = afterGoalCheck
        self.paused = paused
        self.collapsed = collapsed
        self.scrolls = scrolls
        self.drop = drop
        self.onToggle = onToggle
        self.rows = rows
        self.options = options
    }

    public var body: some View {
        let sh = Color.sh
        let shape = RoundedRectangle(cornerRadius: SH.Radius.m)
        VStack(spacing: 0) {
            SHQueueHeader(count: count, paused: paused, afterGoalCheck: afterGoalCheck, collapsed: collapsed, showsOptions: showsOptions,
                          onToggle: onToggle, options: options)
            if !collapsed {
                Group(subviews: rows()) { subviews in
                    // Scrolling, the last row ("Show fewer") stays under the rows that scroll.
                    let pinned = scrolls ? subviews.last : nil
                    VStack(spacing: 0) {
                        if scrolls {
                            ScrollView { list(subviews.dropLast(), first: subviews.first?.id) }
                                .frame(height: CGFloat(SHQueueMetrics.expandedMaxRows) * SHQueueMetrics.rowHeight)
                        } else {
                            list(subviews[...], first: subviews.first?.id)
                        }
                        if let pinned { pinned.overlay(alignment: .top) { SHHairline() } }
                    }
                }
                .overlay(alignment: .top) { SHHairline() }
                // The rows keep to the card's bottom corners; a lifted row floats past its edges.
                .clipShape(SHOutsideBottomCorners(radius: SH.Radius.m), style: FillStyle(eoFill: true))
                .shTransition(.disclosure)
            }
        }
        .background(framed ? sh.bgRaised : .clear, in: shape)
        .shBorder(framed ? sh.lineStrong : .clear, radius: SH.Radius.m)
        .accessibilityElement(children: .contain)
    }

    /// Rows, a hairline above each but the first, and the drop line under them.
    private func list(_ rows: SubviewsCollection.SubSequence, first: Subview.ID?) -> some View {
        VStack(spacing: 0) {
            ForEach(rows) { subview in
                subview.overlay(alignment: .top) {
                    if subview.id != first { SHHairline() }
                }
            }
        }
        .background(alignment: .top) {
            if let drop {
                SHDropIndicator(color: .sh.lantern)
                    .padding(.horizontal, SH.Space.m)
                    .offset(y: CGFloat(drop) * SHQueueMetrics.rowHeight - SHDropIndicator.thickness / 2)
                    .shTransition(.hover)
            }
        }
        .shAnimation(.hover, value: drop)
    }
}

/// Everything around the stack's rows but the two bottom corners the card rounds off (filled
/// even-odd): clipped to it, the rows keep to the card's shape while a lifted row, which a drag
/// keeps within half a row of them, floats past its edges with its shadow.
private struct SHOutsideBottomCorners: Shape {
    let radius: CGFloat
    static let reach = 2 * SHQueueMetrics.rowHeight

    func path(in rect: CGRect) -> Path {
        var path = Path(rect.insetBy(dx: -Self.reach, dy: -Self.reach))
        path.addRect(rect)
        path.addRoundedRect(in: rect, cornerRadii: RectangleCornerRadii(bottomLeading: radius, bottomTrailing: radius))
        return path
    }
}

private struct SHQueueHeader<Options: View>: View {
    let count: Int
    let paused: String?
    let afterGoalCheck: Bool
    let collapsed: Bool
    let showsOptions: Bool
    let onToggle: () -> Void
    @ViewBuilder let options: () -> Options

    var body: some View {
        let sh = Color.sh
        HStack(spacing: SH.Space.m) {
            HStack(spacing: SH.Space.m) {
                SHQueueGlyph().foregroundStyle(sh.textTertiary)
                Text("Up next").font(.shSans(12, .semibold)).foregroundStyle(sh.textSecondary)
                Text("\(count)").font(.shMono(11)).foregroundStyle(sh.textTertiary).monospacedDigit()
                    .shContentTransition(.numeric())
                    .shComponentAnimation(.content, value: count)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Up next, \(count) \(count == 1 ? "message" : "messages")")
            .accessibilityAddTraits(.isHeader)
            if let paused {
                Text("Paused").font(.sh(.caption)).foregroundStyle(sh.textTertiary)
                    .help(paused)
                    .shTransition(.content)
            }
            Spacer(minLength: SH.Space.m)
            if afterGoalCheck {
                Text("after the goal check").font(.shMono(SHGoalMetrics.metaFont)).foregroundStyle(sh.textTertiary)
            }
            if showsOptions { SHOptionsMenu("Queue options", size: SHQueueMetrics.headerButton, content: options) }
            Button(action: onToggle) {
                Image(systemName: "chevron.down")
                    .rotationEffect(.degrees(collapsed ? 180 : 0))
                    .shComponentAnimation(.disclosure, value: collapsed)
            }
            .buttonStyle(.shIcon(size: SHQueueMetrics.headerButton))
            .help(collapsed ? "Expand the queue" : "Collapse the queue")
            .accessibilityLabel(collapsed ? "Expand the queue" : "Collapse the queue")
        }
        .shComponentAnimation(.content, value: paused != nil)
        .padding(.leading, SH.Space.l)
        .padding(.trailing, SH.Space.s)
        .frame(height: SHQueueMetrics.headerHeight)
    }
}

// MARK: Rows

/// An attachment a queued message carries: its image's name, and its thumbnail where this Mac
/// has the bytes (another client's show a photo glyph); or an element picked in the Browser, by
/// its selector (`isElement`).
public struct SHQueueAttachment: Identifiable, Equatable {
    public var id: String
    public var name: String
    public var thumbnail: Image?
    public var isElement: Bool

    public init(id: String, name: String, thumbnail: Image? = nil, isElement: Bool = false) {
        self.id = id
        self.name = name
        self.thumbnail = thumbnail
        self.isElement = isElement
    }

    public static func == (a: Self, b: Self) -> Bool {
        a.id == b.id && a.name == b.name && a.isElement == b.isElement && (a.thumbnail == nil) == (b.thumbnail == nil)
    }
}

/// What a row's buttons do. A nil action hides its button.
public struct SHQueueRowActions {
    /// Steer now (Send now while pi is idle).
    public var steer: (() -> Void)?
    public var subagent: (() -> Void)?
    public var steerLabel: String
    public var steerShortcut: String?
    /// What the action does, for its tooltip and VoiceOver ("Stop the agent and send this now").
    public var steerHelp: String?
    /// Steer now is a labelled button (the glyph and its words) that stays at rest, not an icon on
    /// hover: the first queued row while pi works.
    public var steerLabelled: Bool
    /// Opens the editor (the pencil, or a click on the text).
    public var edit: (() -> Void)?
    public var delete: (() -> Void)?
    public var deleteShortcut: String?
    /// A steering row's Back to the queue.
    public var back: (() -> Void)?

    public init(steer: (() -> Void)? = nil, steerLabel: String = "Steer now", steerShortcut: String? = nil, steerHelp: String? = nil,
                steerLabelled: Bool = false, edit: (() -> Void)? = nil, delete: (() -> Void)? = nil, deleteShortcut: String? = nil,
                back: (() -> Void)? = nil, subagent: (() -> Void)? = nil) {
        self.steer = steer
        self.subagent = subagent
        self.steerLabel = steerLabel
        self.steerShortcut = steerShortcut
        self.steerHelp = steerHelp
        self.steerLabelled = steerLabelled
        self.edit = edit
        self.delete = delete
        self.deleteShortcut = deleteShortcut
        self.back = back
    }
}

/// A drag of a row's grip: how far the pointer has moved, and where it let go.
public struct SHQueueDrag {
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
///   for Steer now, Edit and Delete, built only while the row is hovered or focused. The first
///   queued row while pi works is the exception (`steerLabelled`): its Steer now is a labelled
///   button that is there at rest, with Edit and Delete still on hover in the room beside it.
/// - **Steering:** on `runningTint`, the still steer glyph in the number's place, the "Steering" pill and
///   Back to the queue.
///
/// Hovered it is `bgHover`; with keyboard focus `bgSelected` and the focus ring drawn inside it,
/// since a ring outside would cover its neighbours. Lifted by a drag it floats on a card of its
/// own (`bgRaised` under `bgHover`, the popover's shadow), shifted right of its slot and past
/// the stack's trailing edge (`liftInset`).
public struct SHQueueRow: View {
    public enum Kind: Equatable, Sendable {
        /// Waiting; `number` is its place in the order it goes.
        case queued(number: Int)
        /// Handed to pi, to read once its current tool calls finish.
        case steering
    }

    let text: String
    let attachments: [SHQueueAttachment]
    let kind: Kind
    let hovering: Bool
    let focused: Bool
    let lifted: Bool
    let actions: SHQueueRowActions
    let drag: SHQueueDrag?

    public init(_ text: String, attachments: [SHQueueAttachment] = [], kind: Kind, hovering: Bool = false, focused: Bool = false,
                lifted: Bool = false, actions: SHQueueRowActions = SHQueueRowActions(), drag: SHQueueDrag? = nil) {
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
        let sh = Color.sh
        let steering = kind == .steering
        let active = hovering || focused || lifted
        HStack(spacing: SH.Space.m) {
            grip(shown: active && !steering && drag != nil)
            ZStack {
                switch kind {
                case .queued(let number):
                    SHQueueNumber(number).shTransition(.content)
                case .steering:
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(sh.running)
                        .frame(width: SHQueueMetrics.steerGlyph, height: SHQueueMetrics.steerGlyph)
                        .accessibilityHidden(true)
                        .shTransition(.content)
                }
            }
            .frame(width: steering ? SHQueueMetrics.steerGlyph : SHQueueMetrics.numberSize, height: SHQueueMetrics.numberSize)
            label
            if !attachments.isEmpty {
                HStack(spacing: SH.Space.xs) {
                    ForEach(attachments) { attachment in
                        if attachment.isElement {
                            SHElementChip(attachment.name, size: .compact)
                        } else {
                            SHAttachmentChip(attachment.name, thumbnail: attachment.thumbnail, size: .compact)
                        }
                    }
                }
                .layoutPriority(1)
            }
            ZStack(alignment: .trailing) {
                if steering {
                    HStack(spacing: SH.Space.xs) {
                        SHStatusPill(.running, label: "Steering", symbol: "arrow.turn.down.right")
                        if let back = actions.back {
                            iconButton("arrow.uturn.backward", "Back to the queue", action: back)
                        }
                    }
                    .shTransition(.content)
                } else if actions.steerLabelled, let steer = actions.steer {
                    // Steer now stays put at the slot's trailing edge and Edit and Delete come in before it, in
                    // room that is always reserved: the pointer that aimed at the button never finds another
                    // control under it, and the text never re-truncates.
                    HStack(spacing: SH.Space.xxs) {
                        HStack(spacing: SH.Space.xxs) {
                            if active && !lifted {
                                if let subagent = actions.subagent { iconButton(SHGlyph.gitBranch.symbolName, "Run in subagent", action: subagent) }
                                if let edit = actions.edit { iconButton("pencil", "Edit", action: edit) }
                                if let delete = actions.delete { iconButton("trash", "Delete", shortcut: actions.deleteShortcut, action: delete) }
                            }
                        }
                        .frame(width: SHQueueMetrics.editDeleteWidth + subagentWidth, alignment: .trailing)
                        labelledSteer(steer)
                            .opacity(lifted ? 0 : 1)
                            .allowsHitTesting(!lifted)
                            .accessibilityHidden(lifted)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .shTransition(.content)
                } else {
                    HStack(spacing: SH.Space.xxs) {
                        if active && !lifted {
                            if let steer = actions.steer {
                                iconButton("arrow.turn.down.right", actions.steerLabel, help: actions.steerHelp, shortcut: actions.steerShortcut, action: steer)
                            }
                            if let subagent = actions.subagent { iconButton(SHGlyph.gitBranch.symbolName, "Run in subagent", action: subagent) }
                            if let edit = actions.edit { iconButton("pencil", "Edit", action: edit) }
                            if let delete = actions.delete { iconButton("trash", "Delete", shortcut: actions.deleteShortcut, action: delete) }
                        }
                    }
                    .frame(width: SHQueueMetrics.actionsWidth + subagentWidth, alignment: .trailing)
                    .shTransition(.content)
                }
            }
            .layoutPriority(1)
        }
        .shComponentAnimation(.content, value: kind)
        .padding(.leading, SH.Space.m)
        .padding(.trailing, SH.Space.s)
        .frame(height: SHQueueMetrics.rowHeight)
        .frame(maxWidth: .infinity)
        .background { fill }
        .overlay {
            if focused && !lifted {
                RoundedRectangle(cornerRadius: SH.Radius.s).inset(by: SH.Space.xxs)
                    .strokeBorder(sh.focusRing, lineWidth: SH.Space.xxs)
                    .allowsHitTesting(false)
            }
        }
        .padding(.leading, lifted ? SHQueueMetrics.liftInset.leading : 0)
        .padding(.trailing, lifted ? -SHQueueMetrics.liftInset.trailing : 0)
        .rotationEffect(.degrees(lifted ? SHQueueMetrics.liftTilt : 0))
        .contentShape(Rectangle())
    }

    /// Clear at rest, `bgHover` under the pointer, `bgSelected` with focus, `runningTint` while
    /// steering; a lifted row is a floating card, still under the pointer.
    @ViewBuilder private var fill: some View {
        let sh = Color.sh
        if lifted {
            let card = RoundedRectangle(cornerRadius: SH.Radius.m)
            card.fill(sh.bgRaised)
                .overlay { card.fill(sh.bgHover) }
                .shBorder(sh.lineStrong, radius: SH.Radius.m)
                .shFloatShadow()
        } else {
            Rectangle()
                .fill(kind == .steering ? sh.runningTint : focused ? sh.bgSelected : hovering ? sh.bgHover : Color.clear)
                .shAnimation(.hover, value: hovering)
        }
    }

    private var subagentWidth: CGFloat { actions.subagent == nil ? 0 : SHQueueMetrics.actionSize + SH.Space.xxs }

    private func grip(shown: Bool) -> some View {
        SHGripGlyph()
            .opacity(shown ? 1 : 0)
            .shAnimation(.hover, value: shown)
            .frame(width: SHQueueMetrics.gripSize.width, height: SHQueueMetrics.rowHeight)
            .contentShape(Rectangle())
            #if os(macOS)
            .pointerStyle(drag == nil || kind == .steering ? nil : lifted ? .grabActive : .grabIdle)
            #endif
            .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .onChanged { value in drag?.changed(value.translation.height) }
                .onEnded { value in drag?.ended(value.translation.height) },
                     isEnabled: drag != nil && kind != .steering)
            .accessibilityHidden(true)
    }

    @ViewBuilder private var label: some View {
        let text = Text(text).font(.shSans(13)).foregroundStyle(Color.sh.textPrimary)
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

    /// Steer now with its words (`secondary`, small): the glyph, then "Steer now" ("Send now" while pi is idle),
    /// its tooltip what it does with its chord.
    private func labelledSteer(_ action: @escaping () -> Void) -> some View {
        Button(action: action) { Label(actions.steerLabel, systemImage: "arrow.turn.down.right") }
            .buttonStyle(.sh(.secondary, size: .s))
            .shHelp(actions.steerHelp ?? actions.steerLabel, shortcut: actions.steerShortcut)
            .accessibilityHint(actions.steerHelp ?? "")
    }

    /// `help` is what the tooltip says when the name alone would not tell ("Steer now" stops the agent).
    private func iconButton(_ symbol: String, _ label: String, help: String? = nil, shortcut: String? = nil,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .buttonStyle(.shIcon(size: SHQueueMetrics.actionSize))
            .shHelp(help ?? label, shortcut: shortcut)
            .accessibilityLabel(label)
            .accessibilityHint(help ?? "")
    }
}

/// A message the editor is open on (Queue & steer boards · QueueItem editing), in its place: its
/// number, then the text in a field with a lantern line and ring, and Cancel and Save. ↩ saves,
/// ⇧↩ adds a line, Esc cancels. Save is secondary: Send is the surface's primary action.
public struct SHQueueEditor: View {
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
        let sh = Color.sh
        let field = RoundedRectangle(cornerRadius: SH.Radius.s)
        HStack(alignment: .top, spacing: SH.Space.m) {
            SHQueueNumber(number)
            VStack(alignment: .trailing, spacing: SH.Space.m) {
                TextField(text: $text, selection: $selection, axis: .vertical) { Text("Queued message") }
                    .lineLimit(1...SHQueueMetrics.editorMaxLines)
                    .textFieldStyle(.plain)
                    .font(.shSans(13))
                    .lineSpacing(SHQueueMetrics.editorLineSpacing)
                    .foregroundStyle(sh.textPrimary)
                    .tint(sh.lantern)
                    .autocorrectionDisabled()
                    .focused($focused)
                    .onKeyPress(.return, phases: .down) { press in
                        if let result = SHReturnKey.lineBreak(for: press) { return result }
                        if canSave { onSave() }
                        return .handled
                    }
                    .onKeyPress(.escape) { onCancel(); return .handled }
                    .padding(SHQueueMetrics.editorPadding)
                    .background(sh.bgRaised, in: field)
                    .shBorder(sh.lantern, radius: SH.Radius.s)
                    .background {
                        RoundedRectangle(cornerRadius: SH.Radius.s + SHComposerMetrics.focusRing)
                            .inset(by: -SHComposerMetrics.focusRing).fill(sh.lanternTint)
                    }
                    .accessibilityLabel("Edit queued message \(number)")
                HStack(spacing: SH.Space.s) {
                    Button("Cancel", action: onCancel).buttonStyle(.sh(.ghost, size: .s))
                    Button("Save", action: onSave).buttonStyle(.sh(.secondary, size: .s)).disabled(!canSave)
                }
            }
        }
        .padding(.vertical, SH.Space.m)
        .padding(.leading, SH.Space.xxl)
        .padding(.trailing, SH.Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(sh.bgWindow)
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
public struct SHQueueDeletedRow: View {
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
        let sh = Color.sh
        HStack(spacing: SH.Space.m) {
            Image(systemName: "trash")
                .font(.system(size: SHQueueMetrics.deletedGlyph, weight: .medium))
                .foregroundStyle(sh.textTertiary)
                .accessibilityHidden(true)
            Group {
                if let deleted {
                    Text("Deleted \(Text(deleted).strikethrough())")
                } else {
                    Text("Cleared \(cleared) \(cleared == 1 ? "message" : "messages")")
                }
            }
            .font(.sh(.ui, weight: .regular))
            .foregroundStyle(sh.textTertiary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Undo", action: onUndo).buttonStyle(.shLink(font: .sh(.ui)))
        }
        .padding(.leading, SHQueueMetrics.secondaryInset)
        .padding(.trailing, SH.Space.l)
        .frame(height: SHQueueMetrics.rowHeight)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(deleted.map { "Deleted: \($0)" } ?? "Cleared \(cleared) queued messages")
        .accessibilityAction(named: "Undo", onUndo)
    }
}

/// "Show N more" under a long stack's first rows, or "Show fewer" once it is expanded.
public struct SHQueueMoreRow: View {
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
            .buttonStyle(.shLink(font: .shSans(12)))
            .padding(.leading, SHQueueMetrics.secondaryInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: SHQueueMetrics.moreRowHeight)
    }
}

// MARK: Send menu

/// A way to send a message while pi works (the Send menu's rows).
public struct SHSendOption: Identifiable, Equatable, Sendable {
    public enum Glyph: Equatable, Sendable {
        /// The queue's own glyph.
        case queue
        case symbol(String)
    }

    public var id: String
    public var title: String
    public var detail: String
    public var glyph: Glyph
    /// Its keys, as the store displays them ("↩", "⌘↩"); nil for a row no key sends.
    public var shortcut: String?

    public init(id: String, title: String, detail: String, glyph: Glyph, shortcut: String? = nil) {
        self.id = id
        self.title = title
        self.detail = detail
        self.glyph = glyph
        self.shortcut = shortcut
    }
}

/// The choice at send time (Queue & steer boards · SendMenu), opened by right-clicking or holding
/// Send while pi works: wait for the turn to end, or steer now, each with what it does and its
/// keys (a row no key sends wears none). 268pt on the
/// popover surface; ↑↓ move, ↩ chooses, Esc closes. Nothing about the choice is written under
/// the composer.
public struct SHSendMenu: View {
    let options: [SHSendOption]
    let onChoose: (SHSendOption) -> Void
    let onClose: () -> Void
    @State private var selection: Int
    @FocusState private var focused: Bool

    /// `highlighted` is the row ↩ would choose (the first: Wait for the turn to end).
    public init(options: [SHSendOption], highlighted: Int = 0, onChoose: @escaping (SHSendOption) -> Void,
                onClose: @escaping () -> Void) {
        self.options = options
        self.onChoose = onChoose
        self.onClose = onClose
        _selection = State(initialValue: highlighted)
    }

    public var body: some View {
        let sh = Color.sh
        VStack(alignment: .leading, spacing: SH.Space.xxs) {
            ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                SHMenuRow(highlighted: index == selection, alignment: .top, padding: SHQueueMetrics.sendMenuRowPadding,
                          action: { onChoose(option) }, onHover: { selection = index }) {
                    Group {
                        switch option.glyph {
                        case .queue: SHQueueGlyph(size: SHQueueMetrics.sendMenuGlyph)
                        case .symbol(let name):
                            Image(systemName: name).font(.system(size: SHQueueMetrics.sendMenuGlyph, weight: .medium))
                        }
                    }
                    .foregroundStyle(sh.textSecondary)
                    .frame(width: SHQueueMetrics.sendMenuGlyph, height: SHQueueMetrics.sendMenuGlyph)
                    .padding(.top, SHQueueMetrics.sendMenuTitleInset)
                    VStack(alignment: .leading, spacing: SH.Space.xxs) {
                        Text(option.title).font(.shSans(13, .medium)).foregroundStyle(sh.textPrimary)
                        Text(option.detail).shText(.caption).foregroundStyle(sh.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if let shortcut = option.shortcut { SHKeycap(shortcut).padding(.top, SHQueueMetrics.sendMenuTitleInset) }
                }
                .accessibilityLabel("\(option.title), \(option.detail)")
            }
        }
        .modifier(SHMenuSurface(width: SHQueueMetrics.sendMenuWidth))
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
