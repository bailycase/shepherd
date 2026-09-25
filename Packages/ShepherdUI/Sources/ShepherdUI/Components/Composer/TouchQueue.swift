import SwiftUI

// "Up next" for touch (MobileQueue, MobileSteer, iPadQueue boards): the Mac's queue stack
// (`NWQueueStack`, `NWQueueRow`) is pointer-first (40pt rows, actions on hover, a drag grip).
// On a phone or iPad the rows are at least 44pt, a queued row's actions live in its swipe
// actions and its long-press menu (the app attaches both), and a steering row keeps Back to the
// queue as a 44pt button. The number ring and the queue glyph are the Mac's.

public enum NWTouchQueueMetrics {
    /// The header: the queue glyph, "Up next", the count, and the ••• options.
    public static let headerHeight: CGFloat = NW.Height.touch
    /// A row's minimum height (the boards' 48pt; a steering row grows to its two lines).
    public static let rowHeight: CGFloat = 48
    /// The queue glyph in the header.
    public static let glyph: CGFloat = 14
    /// The still steer glyph in a steering row's number slot (MobileQueue; LiveText: waiting
    /// isn't working).
    public static let steerGlyph: CGFloat = 15
    /// Rows the stack shows before it scrolls inside, so it never takes the thread's room.
    public static let visibleRows = 3
}

/// The stack's card: `bgRaised`, a `lineStrong` line, the boards' 12pt corners, its header, then
/// its rows with a hairline above each. The app hands it the rows (inside the scroll container
/// that carries their swipe actions) and the ••• menu's content.
///
/// A paused queue says so in its header, and, with no hover to reveal the Mac's per-row Send now
/// or tooltip, shows Send now there (the ••• menu's Send all now), its reason as the hint.
public struct NWTouchQueueCard<Rows: View, Options: View>: View {
    let count: Int
    let paused: String?
    let resume: (() -> Void)?
    @ViewBuilder let rows: () -> Rows
    @ViewBuilder let options: () -> Options

    /// `count` is every message in the queue, steering ones included. `paused` says why the
    /// queue waits (pi was stopped, or a turn failed), nil while it goes on its own; `resume`
    /// sends what it holds now, shown only while it is paused.
    public init(count: Int, paused: String? = nil, resume: (() -> Void)? = nil,
                @ViewBuilder rows: @escaping () -> Rows, @ViewBuilder options: @escaping () -> Options) {
        self.count = count
        self.paused = paused
        self.resume = resume
        self.rows = rows
        self.options = options
    }

    public var body: some View {
        let nw = Color.nw
        let shape = RoundedRectangle(cornerRadius: NW.Radius.l)
        VStack(spacing: 0) {
            NWTouchQueueHeader(count: count, paused: paused, resume: paused == nil ? nil : resume, options: options)
            rows().overlay(alignment: .top) { NWHairline() }
        }
        .background(nw.bgRaised, in: shape)
        .clipShape(shape)
        .nwBorder(nw.lineStrong, radius: NW.Radius.l)
        .accessibilityElement(children: .contain)
    }
}

private struct NWTouchQueueHeader<Options: View>: View {
    let count: Int
    let paused: String?
    let resume: (() -> Void)?
    @ViewBuilder let options: () -> Options
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let nw = Color.nw
        // At accessibility sizes Send now takes a row of its own under the title, which would
        // otherwise truncate beside it.
        let stacked = typeSize.isAccessibilitySize
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: NW.Space.m) {
                HStack(spacing: NW.Space.m) {
                    NWQueueGlyph(size: NWTouchQueueMetrics.glyph).foregroundStyle(nw.textTertiary)
                    Text("Up next").font(.nw(.ui, weight: .semibold)).foregroundStyle(nw.textSecondary)
                    Text("\(count)").font(.nw(.mono)).foregroundStyle(nw.textTertiary).monospacedDigit()
                        .nwContentTransition(.numeric())
                        .nwComponentAnimation(.content, value: count)
                    if paused != nil {
                        Text("Paused").font(.nw(.caption)).foregroundStyle(nw.textTertiary).nwTransition(.content)
                    }
                }
                .lineLimit(1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Up next, \(count) \(count == 1 ? "message" : "messages")\(paused != nil ? ", paused" : "")")
                .accessibilityHint(paused ?? "")
                .accessibilityAddTraits(.isHeader)
                Spacer(minLength: NW.Space.m)
                if !stacked { sendNow }
                Menu(content: options) {
                    Image(systemName: "ellipsis")
                        .font(.nw(.ui, weight: .semibold))
                        .foregroundStyle(nw.textSecondary)
                        .frame(width: NW.Height.touch, height: NW.Height.touch)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Queue options")
            }
            .frame(minHeight: NWTouchQueueMetrics.headerHeight)
            if stacked, resume != nil {
                sendNow.padding(.bottom, NW.Space.m)
            }
        }
        // "Paused" and Send now come and go on their own: a queue can pause while its
        // messages can't be sent yet.
        .nwComponentAnimation(.content, value: [paused != nil, resume != nil])
        .padding(.leading, NW.Space.l)
    }

    @ViewBuilder private var sendNow: some View {
        if let resume {
            Button("Send now", systemImage: "arrow.up", action: resume)
                .buttonStyle(.nw(.secondary, size: .s))
                .accessibilityHint(paused ?? "")
                .nwTransition(.content)
        }
    }
}

/// One row of the touch stack:
///
/// - **Queued:** its number (the order it goes), the text on up to two lines, and a photo glyph
///   with a count for its images. Its actions are the app's swipe actions and long-press menu.
/// - **Steering:** on `runningTint`, the still `running` steer glyph in the number's place, the text, "↳
///   Steering" under it, and Back to the queue.
/// - **Deleted / Cleared:** where a message was deleted (or the queue cleared), with Undo.
public struct NWTouchQueueRow: View {
    public enum Kind: Equatable, Sendable {
        case queued(number: Int)
        case steering
        case deleted
        case cleared(count: Int)
    }

    let text: String
    let images: Int
    let kind: Kind
    let held: Bool
    let back: (() -> Void)?
    let undo: (() -> Void)?

    /// `held` marks a message an editor is open on elsewhere. `back` is a steering row's Back
    /// to the queue; `undo` a deleted row's Undo.
    public init(_ text: String, images: Int = 0, kind: Kind, held: Bool = false,
                back: (() -> Void)? = nil, undo: (() -> Void)? = nil) {
        self.text = text
        self.images = images
        self.kind = kind
        self.held = held
        self.back = back
        self.undo = undo
    }

    public var body: some View {
        switch kind {
        case .queued, .steering: message
        case .deleted, .cleared: deletedRow
        }
    }

    private var message: some View {
        let nw = Color.nw
        let steering = kind == .steering
        return HStack(spacing: NW.Space.l) {
            ZStack {
                switch kind {
                case .queued(let number): NWQueueNumber(number).nwTransition(.content)
                default:
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(nw.running)
                        .frame(width: NWTouchQueueMetrics.steerGlyph, height: NWTouchQueueMetrics.steerGlyph)
                        .accessibilityHidden(true)
                        .nwTransition(.content)
                }
            }
            .frame(width: NWQueueMetrics.numberSize + NW.Space.xs)
            VStack(alignment: .leading, spacing: NW.Space.xxs) {
                Text(text).font(.nw(.ui, weight: .regular)).foregroundStyle(nw.textPrimary)
                    .lineLimit(steering ? 1 : 2).truncationMode(.tail)
                if steering {
                    Label("Steering", systemImage: "arrow.turn.down.right")
                        .font(.nw(.caption, weight: .medium)).foregroundStyle(nw.running)
                        .labelStyle(NWTouchQueueInlineLabel())
                } else if held {
                    Label("Being edited", systemImage: "pencil")
                        .font(.nw(.caption)).foregroundStyle(nw.textTertiary)
                        .labelStyle(NWTouchQueueInlineLabel())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if images > 0 {
                Label("\(images)", systemImage: "photo")
                    .font(.nw(.caption)).foregroundStyle(nw.textTertiary)
                    .labelStyle(NWTouchQueueInlineLabel())
                    .accessibilityLabel(images == 1 ? "1 image" : "\(images) images")
            }
            if steering, let back {
                Button(action: back) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.nw(.ui, weight: .medium))
                        .foregroundStyle(nw.textSecondary)
                        .frame(width: NW.Height.touch, height: NW.Height.touch)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back to the queue")
            }
        }
        .padding(.leading, NW.Space.l)
        .padding(.trailing, steering && back != nil ? NW.Space.xs : NW.Space.l)
        .padding(.vertical, NW.Space.s)
        .frame(minHeight: NWTouchQueueMetrics.rowHeight)
        .frame(maxWidth: .infinity)
        .background(steering ? nw.runningTint : nw.bgRaised)
        .nwComponentAnimation(.content, value: kind)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .modifier(NWTouchNamedAction(name: "Back to the queue", action: steering ? back : nil))
    }

    private var accessibilityLabel: String {
        switch kind {
        case .queued(let number): "Queued \(number): \(text)"
        case .steering: "Steering: \(text)"
        default: text
        }
    }

    private var deletedRow: some View {
        let nw = Color.nw
        let label: Text = if case .cleared(let count) = kind {
            Text("Cleared \(count) \(count == 1 ? "message" : "messages")")
        } else {
            Text("Deleted \(Text(text).strikethrough())")
        }
        return HStack(spacing: NW.Space.l) {
            Image(systemName: "trash").font(.nw(.caption)).foregroundStyle(nw.textTertiary)
                .frame(width: NWQueueMetrics.numberSize + NW.Space.xs)
                .accessibilityHidden(true)
            label.font(.nw(.ui, weight: .regular)).foregroundStyle(nw.textTertiary)
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let undo {
                Button("Undo", action: undo)
                    .buttonStyle(.nwLink(font: .nw(.ui, weight: .medium)))
                    .frame(minWidth: NW.Height.touch, minHeight: NW.Height.touch)
                    .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, NW.Space.l)
        .frame(minHeight: NWTouchQueueMetrics.rowHeight)
        .frame(maxWidth: .infinity)
        .background(nw.bgRaised)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(kind == .deleted ? "Deleted: \(text)" : "Queue cleared")
        .modifier(NWTouchNamedAction(name: "Undo", action: undo))
    }
}

/// A VoiceOver action for a button the row's combined element would otherwise hide.
private struct NWTouchNamedAction: ViewModifier {
    let name: String
    let action: (() -> Void)?

    func body(content: Content) -> some View {
        if let action { content.accessibilityAction(named: name, action) } else { content }
    }
}

/// A glyph and a word at caption size, 4pt apart.
private struct NWTouchQueueInlineLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: NW.Space.xs) {
            configuration.icon
            configuration.title
        }
    }
}
