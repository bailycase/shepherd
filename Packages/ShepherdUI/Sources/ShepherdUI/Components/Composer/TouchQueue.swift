import SwiftUI

// "Up next" for touch (MobileQueue, MobileSteer, iPadQueue boards): the Mac's queue stack
// (`SHQueueStack`, `SHQueueRow`) is pointer-first (40pt rows, actions on hover, a drag grip).
// On a phone or iPad the rows are at least 44pt, a queued row's actions live in its swipe
// actions and its long-press menu (the app attaches both), and a steering row keeps Back to the
// queue as a 44pt button. The number ring and the queue glyph are the Mac's.

public enum SHTouchQueueMetrics {
    /// The header: the queue glyph, "Up next", the count, and the ••• options.
    public static let headerHeight: CGFloat = SH.Height.touch
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
///
/// Unframed, it draws no card of its own: it is Up next's section of the dock (`SHDockStack`),
/// under the subagents, and rounds only its bottom corners.
public struct SHTouchQueueCard<Rows: View, Options: View>: View {
    let count: Int
    let framed: Bool
    let afterGoalCheck: Bool
    let collapsed: Bool
    let onToggle: (() -> Void)?
    let paused: String?
    let resume: (() -> Void)?
    @ViewBuilder let rows: () -> Rows
    @ViewBuilder let options: () -> Options

    /// `count` is every message in the queue, steering ones included. `paused` says why the
    /// queue waits (pi was stopped, or a turn failed), nil while it goes on its own; `resume`
    /// sends what it holds now, shown only while it is paused.
    public init(count: Int, paused: String? = nil, resume: (() -> Void)? = nil, framed: Bool = true, afterGoalCheck: Bool = false,
                collapsed: Bool = false, onToggle: (() -> Void)? = nil,
                @ViewBuilder rows: @escaping () -> Rows, @ViewBuilder options: @escaping () -> Options) {
        self.count = count
        self.framed = framed
        self.afterGoalCheck = afterGoalCheck
        self.collapsed = collapsed
        self.onToggle = onToggle
        self.paused = paused
        self.resume = resume
        self.rows = rows
        self.options = options
    }

    public var body: some View {
        let sh = Color.sh
        let radius = SH.Radius.l
        let shape = UnevenRoundedRectangle(cornerRadii: RectangleCornerRadii(
            topLeading: framed ? radius : 0, bottomLeading: radius, bottomTrailing: radius, topTrailing: framed ? radius : 0))
        VStack(spacing: 0) {
            SHTouchQueueHeader(count: count, paused: paused, resume: paused == nil ? nil : resume,
                               afterGoalCheck: afterGoalCheck, collapsed: collapsed, onToggle: onToggle, options: options)
            if !collapsed { rows().overlay(alignment: .top) { SHHairline() } }
        }
        .background(framed ? sh.bgRaised : .clear, in: shape)
        .clipShape(shape)
        .shBorder(framed ? sh.lineStrong : .clear, radius: radius)
        .accessibilityElement(children: .contain)
    }
}

private struct SHTouchQueueHeader<Options: View>: View {
    let count: Int
    let paused: String?
    let resume: (() -> Void)?
    let afterGoalCheck: Bool
    let collapsed: Bool
    let onToggle: (() -> Void)?
    @ViewBuilder let options: () -> Options
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let sh = Color.sh
        // At accessibility sizes Send now takes a row of its own under the title, which would
        // otherwise truncate beside it.
        let stacked = typeSize.isAccessibilitySize
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: SH.Space.m) {
                HStack(spacing: SH.Space.m) {
                    SHQueueGlyph(size: SHTouchQueueMetrics.glyph).foregroundStyle(sh.textTertiary)
                    Text("Up next").font(.sh(.ui, weight: .semibold)).foregroundStyle(sh.textSecondary)
                    Text("\(count)").font(.sh(.mono)).foregroundStyle(sh.textTertiary).monospacedDigit()
                        .shContentTransition(.numeric())
                        .shComponentAnimation(.content, value: count)
                    if paused != nil {
                        Text("Paused").font(.sh(.caption)).foregroundStyle(sh.textTertiary).shTransition(.content)
                    }
                }
                .lineLimit(1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Up next, \(count) \(count == 1 ? "message" : "messages")\(paused != nil ? ", paused" : "")")
                .accessibilityHint(paused ?? "")
                .accessibilityAddTraits(.isHeader)
                Spacer(minLength: SH.Space.m)
                if afterGoalCheck {
                    Text("after the goal check").font(.shMono(SHGoalMetrics.metaFont)).foregroundStyle(sh.textTertiary)
                        .lineLimit(1).minimumScaleFactor(0.75)
                }
                if !stacked { sendNow }
                Menu(content: options) {
                    Image(systemName: "ellipsis")
                        .font(.sh(.ui, weight: .semibold))
                        .foregroundStyle(sh.textSecondary)
                        .frame(width: SH.Height.touch, height: SH.Height.touch)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Queue options")
                if let onToggle {
                    Button(action: onToggle) {
                        Image(systemName: collapsed ? "chevron.up" : "chevron.down")
                            .foregroundStyle(sh.textSecondary)
                            .frame(width: SH.Height.touch, height: SH.Height.touch)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(collapsed ? "Expand the queue" : "Collapse the queue")
                }
            }
            .frame(minHeight: SHTouchQueueMetrics.headerHeight)
            if stacked, resume != nil {
                sendNow.padding(.bottom, SH.Space.m)
            }
        }
        // "Paused" and Send now come and go on their own: a queue can pause while its
        // messages can't be sent yet.
        .shComponentAnimation(.content, value: [paused != nil, resume != nil])
        .padding(.leading, SH.Space.l)
    }

    @ViewBuilder private var sendNow: some View {
        if let resume {
            Button("Send now", systemImage: "arrow.up", action: resume)
                .buttonStyle(.sh(.secondary, size: .s))
                .accessibilityHint(paused ?? "")
                .shTransition(.content)
        }
    }
}

/// One row of the touch stack:
///
/// - **Queued:** its number (the order it goes), the text on up to two lines, and a photo glyph
///   with a count for its images. Its actions are the app's swipe actions and long-press menu. The
///   first queued row while pi works also wears **Steer now** as a labelled button (`steer`), since
///   touch has no hover to reveal it as the Mac's does.
/// - **Steering:** on `runningTint`, the still `running` steer glyph in the number's place, the text, "↳
///   Steering" under it (on iPad, `wide`, the "Steering" pill after the text; iPadQueue), and Back to
///   the queue.
/// - **Deleted / Cleared:** where a message was deleted (or the queue cleared), with Undo.
public struct SHTouchQueueRow: View {
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
    let wide: Bool
    let steer: (() -> Void)?
    let steerLabel: String
    let back: (() -> Void)?
    let undo: (() -> Void)?

    /// `held` marks a message an editor is open on elsewhere. `steer` is a queued row's labelled
    /// Steer now (`steerLabel`: Steer now, or Send now while pi is idle); `back` a steering row's Back
    /// to the queue; `undo` a deleted row's Undo. `wide` (iPad) puts a steering row's pill
    /// after its text.
    public init(_ text: String, images: Int = 0, kind: Kind, held: Bool = false, wide: Bool = false,
                steer: (() -> Void)? = nil, steerLabel: String = "Steer now",
                back: (() -> Void)? = nil, undo: (() -> Void)? = nil) {
        self.text = text
        self.images = images
        self.kind = kind
        self.held = held
        self.wide = wide
        self.steer = steer
        self.steerLabel = steerLabel
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
        let sh = Color.sh
        let steering = kind == .steering
        // The row's text and its Back to the queue are one VoiceOver element; Steer now, which the app also
        // offers as a named action, stays a button of its own beside it.
        let content = HStack(spacing: SH.Space.l) {
            ZStack {
                switch kind {
                case .queued(let number): SHQueueNumber(number).shTransition(.content)
                default:
                    Image(systemName: "arrow.turn.down.right")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(sh.running)
                        .frame(width: SHTouchQueueMetrics.steerGlyph, height: SHTouchQueueMetrics.steerGlyph)
                        .accessibilityHidden(true)
                        .shTransition(.content)
                }
            }
            .frame(width: SHQueueMetrics.numberSize + SH.Space.xs)
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                Text(text).font(.sh(.ui, weight: .regular)).foregroundStyle(sh.textPrimary)
                    .lineLimit(steering ? 1 : 2).truncationMode(.tail)
                if steering, !wide {
                    Label("Steering", systemImage: "arrow.turn.down.right")
                        .font(.sh(.caption, weight: .medium)).foregroundStyle(sh.running)
                        .labelStyle(SHTouchQueueInlineLabel())
                } else if held {
                    Label("Being edited", systemImage: "pencil")
                        .font(.sh(.caption)).foregroundStyle(sh.textTertiary)
                        .labelStyle(SHTouchQueueInlineLabel())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if steering, wide {
                SHStatusPill(.running, label: "Steering", symbol: "arrow.turn.down.right").fixedSize()
            }
            if images > 0 {
                Label("\(images)", systemImage: "photo")
                    .font(.sh(.caption)).foregroundStyle(sh.textTertiary)
                    .labelStyle(SHTouchQueueInlineLabel())
                    .accessibilityLabel(images == 1 ? "1 image" : "\(images) images")
            }
            if steering, let back {
                Button(action: back) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.sh(.ui, weight: .medium))
                        .foregroundStyle(sh.textSecondary)
                        .frame(width: SH.Height.touch, height: SH.Height.touch)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back to the queue")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .modifier(SHTouchNamedAction(name: "Back to the queue", action: steering ? back : nil))
        return HStack(spacing: SH.Space.m) {
            content
            if !steering, let steer {
                Button(action: steer) { Label(steerLabel, systemImage: "arrow.turn.down.right") }
                    .buttonStyle(.sh(.secondary, size: .s))
                    .fixedSize()
                    .shTransition(.content)
            }
        }
        .padding(.leading, SH.Space.l)
        .padding(.trailing, steering && back != nil ? SH.Space.xs : SH.Space.l)
        .padding(.vertical, SH.Space.s)
        .frame(minHeight: SHTouchQueueMetrics.rowHeight)
        .frame(maxWidth: .infinity)
        .background(steering ? sh.runningTint : sh.bgRaised)
        .shComponentAnimation(.content, value: kind)
        .contentShape(Rectangle())
    }

    private var accessibilityLabel: String {
        switch kind {
        case .queued(let number): "Queued \(number): \(text)"
        case .steering: "Steering: \(text)"
        default: text
        }
    }

    private var deletedRow: some View {
        let sh = Color.sh
        let label: Text = if case .cleared(let count) = kind {
            Text("Cleared \(count) \(count == 1 ? "message" : "messages")")
        } else {
            Text("Deleted \(Text(text).strikethrough())")
        }
        return HStack(spacing: SH.Space.l) {
            Image(systemName: "trash").font(.sh(.caption)).foregroundStyle(sh.textTertiary)
                .frame(width: SHQueueMetrics.numberSize + SH.Space.xs)
                .accessibilityHidden(true)
            label.font(.sh(.ui, weight: .regular)).foregroundStyle(sh.textTertiary)
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let undo {
                Button("Undo", action: undo)
                    .buttonStyle(.shLink(font: .sh(.ui, weight: .medium)))
                    .frame(minWidth: SH.Height.touch, minHeight: SH.Height.touch)
                    .contentShape(Rectangle())
            }
        }
        .padding(.horizontal, SH.Space.l)
        .frame(minHeight: SHTouchQueueMetrics.rowHeight)
        .frame(maxWidth: .infinity)
        .background(sh.bgRaised)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(kind == .deleted ? "Deleted: \(text)" : "Queue cleared")
        .modifier(SHTouchNamedAction(name: "Undo", action: undo))
    }
}

/// A VoiceOver action for a button the row's combined element would otherwise hide.
private struct SHTouchNamedAction: ViewModifier {
    let name: String
    let action: (() -> Void)?

    func body(content: Content) -> some View {
        if let action { content.accessibilityAction(named: name, action) } else { content }
    }
}

/// A glyph and a word at caption size, 4pt apart.
private struct SHTouchQueueInlineLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: SH.Space.xs) {
            configuration.icon
            configuration.title
        }
    }
}
