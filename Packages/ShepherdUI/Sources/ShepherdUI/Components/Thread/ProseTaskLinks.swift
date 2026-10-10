import SwiftUI

// A Project coordinator's typed task reference in prose (ProjectLead-Question, -Resolved: "The [Gift card market scan] and the ..."):
// a standard Markdown link whose URL names the Project and the task, `[words](shepherd-project-task://<projectID>/<taskID>)`.
// The Project conversation hands this file the references that resolve against the owner's CURRENT Project; a link not in
// that table (stale, another Project's, malformed, or only half written while a reply streams) is drawn as the plain words,
// never as a link. Every other thread has no table and draws links as it always did.

/// The references of one Project's conversation that resolve now, keyed by their exact URL. The chip shows the task's own
/// current title (owner data), never the words the model wrote, so a renamed or duplicated title still names the right task.
public struct NWProseTaskLinks: Equatable, Sendable {
    public struct Link: Equatable, Sendable {
        public let title: String
        public let tone: NWLeadTaskCard.Tone
        public init(title: String, tone: NWLeadTaskCard.Tone) { self.title = title; self.tone = tone }
    }

    public static let scheme = "shepherd-project-task"
    public var links: [String: Link]
    public init(links: [String: Link]) { self.links = links }

    /// Whether `text` carries a reference: a cheap test before any run is walked.
    static func hasReference(_ text: AttributedString) -> Bool {
        text.runs.contains { $0.link?.scheme == scheme }
    }

    /// `text` with every reference reduced to its plain words.
    static func inert(_ text: AttributedString) -> AttributedString {
        var text = text
        for run in text.runs where run.link?.scheme == scheme {
            text[run.range].link = nil
            text[run.range].foregroundColor = nil
        }
        return text
    }
}

extension EnvironmentValues {
    /// nil in every ordinary thread. Set only by a Project's conversation.
    @Entry public var nwProseTaskLinks: NWProseTaskLinks? = nil
}

/// Marks the runs of a chip so `NWTaskChipRenderer` draws behind them: the tone of its dot.
struct NWTaskChipAttribute: TextAttribute {
    /// The reference's own URL: the identity of the chip (the press hands it back to the conversation's `openURL`).
    let url: String
    let title: String
    let tone: NWLeadTaskCard.Tone
    /// The zero-width run that holds the dot's room: it starts a chip, and its own bounds say nothing about where.
    var isRoom = false
}

enum NWTaskChipText {
    /// The paragraph as one `Text`: each resolving reference as a chip (a leading run that holds the dot's room, then the title in
    /// 500 `running`), an unresolved one as its plain words.
    @MainActor static func text(_ source: AttributedString, links: NWProseTaskLinks, size: NWProseSize) -> Text {
        let pad = NWLeadMetrics.taskLinkPad
        var result = Text(verbatim: "")
        for run in source.runs {
            var piece = AttributedString(source[run.range])
            guard let url = run.link, url.scheme == NWProseTaskLinks.scheme else {
                result = Text("\(result)\(Text(piece))")
                continue
            }
            guard let link = links.links[url.absoluteString] else {
                // Inert: the words as written, with no link and no link color.
                result = Text("\(result)\(Text(NWProseTaskLinks.inert(piece)))")
                continue
            }
            // Non-breaking, so a chip stays one box on one line unless it is wider than the column.
            var title = AttributedString(link.title.replacingOccurrences(of: " ", with: "\u{00A0}"))
            title.font = Font.nw(.body, weight: .medium, size: size)
            title.foregroundColor = Color.nw.running
            if let last = title.characters.indices.last { title[last..<title.endIndex].kern = pad }
            // A hair space (a real glyph: a zero-width one is dropped from the layout), kerned to the room the padding, the dot and its gap take. The press target is an overlay button over the chip (`NWTaskChipPressTargets`), not a text link.
            // A word joiner follows it, so the dot never ends a line without its title.
            var room = AttributedString("\u{200A}\u{2060}")
            room.kern = pad + NWLeadMetrics.taskLinkDot + NWLeadMetrics.taskLinkGap
            let chip = { (isRoom: Bool) in NWTaskChipAttribute(url: url.absoluteString, title: link.title, tone: link.tone, isRoom: isRoom) }
            result = Text("\(result)\(Text(room).customAttribute(chip(true)))\(Text(title).customAttribute(chip(false)))")
        }
        return result
    }
}

/// One chip's box on one line of the laid-out paragraph, in the text's own coordinates: the board's inline box, a line tall.
struct NWTaskChipBox: Identifiable {
    let url: String
    let title: String
    let tone: NWLeadTaskCard.Tone
    let rect: CGRect
    /// 0 for a chip's first line; a title wider than the column wraps and has more.
    let fragment: Int
    var id: String { "\(url)#\(rect.minX)#\(rect.minY)" }

    static func boxes(in layout: Text.Layout, halfLeading: CGFloat) -> [NWTaskChipBox] {
        var found: [NWTaskChipBox] = []
        // Which line of ITS OWN mention a box is: a mention starts at its room run and continues over every wrapped line, so a later,
        // separate mention of the same task is a new mention (fragment 0), never a continuation.
        var fragment = 0
        for line in layout {
            var open: (chip: NWTaskChipAttribute, rect: CGRect)?
            func finish() {
                guard let (chip, rect) = open else { return }
                open = nil
                found.append(NWTaskChipBox(url: chip.url, title: chip.title, tone: chip.tone, rect: rect.insetBy(dx: 0, dy: -halfLeading), fragment: fragment))
                fragment += 1
            }
            for run in line {
                if let chip = run[NWTaskChipAttribute.self] {
                    // The room run starts a mention, so the box and the dot are anchored on it, whatever the title's width.
                    let bounds = run.typographicBounds.rect
                    if chip.isRoom { finish(); fragment = 0 }
                    open = (open?.chip ?? chip, open?.rect.union(bounds) ?? bounds)
                } else {
                    finish()
                }
            }
            finish()
        }
        return found
    }
}

/// Draws the chip behind each stretch of its runs (radius 4, `runningTint`, a 6pt dot in the task's tone 4pt in from the left edge),
/// then every run over it. The chip is the line box tall, as the board's inline box is.
struct NWTaskChipRenderer: TextRenderer {
    /// Half the leading a line adds, so the chip reaches the board's line-height-tall box.
    let halfLeading: CGFloat
    /// Read where the view is built (the main actor): `draw` is not isolated to it.
    let fill: Color
    let running: Color
    let attention: Color
    let resolved: Color

    @MainActor init(halfLeading: CGFloat) {
        self.halfLeading = halfLeading
        fill = Color.nw.runningTint
        running = Color.nw.running
        attention = Color.nw.lantern
        resolved = Color.nw.textTertiary
    }

    var displayPadding: EdgeInsets { EdgeInsets(top: halfLeading, leading: 0, bottom: halfLeading, trailing: 0) }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for box in NWTaskChipBox.boxes(in: layout, halfLeading: halfLeading) {
            context.fill(RoundedRectangle(cornerRadius: NW.Radius.xs).path(in: box.rect), with: .color(fill))
            let dot = NWLeadMetrics.taskLinkDot
            let color: Color = switch box.tone {
            case .running: running
            case .attention: attention
            case .resolved: resolved
            }
            // The dot belongs to the chip's first line only; a wrapped title continues under it without another.
            if box.fragment == 0 {
                context.fill(Circle().path(in: CGRect(x: box.rect.minX + NWLeadMetrics.taskLinkPad, y: box.rect.midY - dot / 2, width: dot, height: dot)),
                             with: .color(color))
            }
        }
        for line in layout { context.draw(line) }
    }
}

/// The chips' press targets: one invisible, labelled button over each chip's box, at least 24pt tall (the chip stays the board's line
/// box), found from the text's own layout (`Text.LayoutKey`), so they follow the wrapping. A chip's later lines press too but are not
/// separate controls to an assistive client. Pressing hands the reference's URL to the conversation's `openURL`.
struct NWTaskChipPressTargets: ViewModifier {
    let halfLeading: CGFloat
    @Environment(\.openURL) private var openURL

    func body(content: Content) -> some View {
        content.overlayPreferenceValue(Text.LayoutKey.self) { anchored in
            GeometryReader { proxy in
                ForEach(Array(anchored.enumerated()), id: \.offset) { _, item in
                    let origin = proxy[item.origin]
                    ForEach(NWTaskChipBox.boxes(in: item.layout, halfLeading: halfLeading)) { box in
                        let height = max(box.rect.height, NWLeadMetrics.chipPressHeight)
                        Button { if let url = URL(string: box.url) { openURL(url) } } label: { Color.clear.contentShape(Rectangle()) }
                            .buttonStyle(.plain)
                            .frame(width: box.rect.width, height: height)
                            .position(x: origin.x + box.rect.midX, y: origin.y + box.rect.midY)
                            .accessibilityLabel("Open \(box.title), \(Self.word(box.tone))")
                            .accessibilityHidden(box.fragment > 0)
                    }
                }
            }
        }
    }

    static func word(_ tone: NWLeadTaskCard.Tone) -> String {
        switch tone {
        case .running: "working"
        case .attention: "needs you"
        case .resolved: "resolved"
        }
    }
}
